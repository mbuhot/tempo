//// Composes a `pog` list query for the data-table reads from only the fragments a
//// request actually needs. Each present filter folds one `WHERE` condition into the
//// builder and binds its own `$N` param; absent filters emit nothing. Filter values
//// are always bound parameters; the only request-derived strings that reach the SQL
//// text are sort keys, and those pass through a caller-supplied allowlist (`resolve`)
//// to fixed column literals, so the builder is injection-safe by construction.
////
//// Typical use (the fixed prefix/suffix SQL and the sort allowlist stay per-table):
////
////   let #(built, paging) =
////     builder.new([pog.calendar_date(as_of)])
////     |> builder.select("page.status", builder.select_values(filters, "status"))
////     |> builder.date_range("page.billing_from", lo, hi)
////     |> builder.number_range("page.total::numeric", min, max)
////     |> builder.limit_offset(limit, offset)
////   let sql = prefix <> builder.where_clause(built)
////     <> builder.order_by(sort, default_key, resolve, "page.id DESC") <> paging
////   list.fold(builder.params(built), pog.query(sql), pog.parameter)

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleam/time/calendar.{type Date}
import pog
import shared/table/query.{type FilterValue, DateRange, NumberRange, SelectValue}
import shared/table/sort.{type Sort, Sort}
import shared/wire

/// The list query under construction: the `WHERE` conditions and bound params
/// gathered so far (both newest-first), and the next `$N` placeholder number.
pub opaque type Builder {
  Builder(wheres: List(String), params: List(pog.Value), next: Int)
}

/// Seeds the builder with the fixed params the query prefix already references
/// (e.g. an `as_of` bound to `$1`); the next fragment binds `$<len + 1>`.
pub fn new(seed: List(pog.Value)) -> Builder {
  Builder(wheres: [], params: list.reverse(seed), next: list.length(seed) + 1)
}

/// The bound params in `$1..$N` order, ready to fold onto `pog.query`.
pub fn params(builder: Builder) -> List(pog.Value) {
  list.reverse(builder.params)
}

/// Binds a param, returning the updated builder and the `$N` placeholder it took.
/// Use for fragments the standard helpers don't cover; pair with `condition`.
pub fn bind(builder: Builder, value: pog.Value) -> #(Builder, String) {
  let placeholder = "$" <> int.to_string(builder.next)
  #(
    Builder(
      ..builder,
      params: [value, ..builder.params],
      next: builder.next + 1,
    ),
    placeholder,
  )
}

/// Adds a raw `WHERE` condition. The string must contain only trusted SQL and
/// placeholders from `bind` — never an interpolated request value.
pub fn condition(builder: Builder, condition: String) -> Builder {
  Builder(..builder, wheres: [condition, ..builder.wheres])
}

/// The assembled `WHERE` clause, or `""` when no filters applied.
pub fn where_clause(builder: Builder) -> String {
  case list.reverse(builder.wheres) {
    [] -> ""
    conditions -> " WHERE " <> string.join(conditions, " AND ")
  }
}

/// `column = ANY($n::text[])` for a multi-select over a scalar text column.
pub fn select(
  builder: Builder,
  column: String,
  values: Option(List(String)),
) -> Builder {
  case values {
    None -> builder
    Some(values) -> {
      let #(builder, placeholder) = bind(builder, text_array(values))
      condition(builder, column <> " = ANY(" <> placeholder <> "::text[])")
    }
  }
}

/// `column && $n::text[]` for a multi-select over a text-array column (overlap).
pub fn overlaps(
  builder: Builder,
  column: String,
  values: Option(List(String)),
) -> Builder {
  case values {
    None -> builder
    Some(values) -> {
      let #(builder, placeholder) = bind(builder, text_array(values))
      condition(builder, column <> " && " <> placeholder <> "::text[]")
    }
  }
}

/// `column >= lo` and/or `column <= hi`, binding only the bounds that are present.
pub fn number_range(
  builder: Builder,
  column: String,
  min: Option(Float),
  max: Option(Float),
) -> Builder {
  builder
  |> number_bound(column, ">=", min)
  |> number_bound(column, "<=", max)
}

fn number_bound(
  builder: Builder,
  column: String,
  op: String,
  value: Option(Float),
) -> Builder {
  case value {
    None -> builder
    Some(amount) -> {
      let #(builder, placeholder) = bind(builder, pog.float(amount))
      condition(
        builder,
        column <> " " <> op <> " " <> placeholder <> "::numeric",
      )
    }
  }
}

/// `column >= from` and/or `column <= to`, binding only the bounds that are present.
pub fn date_range(
  builder: Builder,
  column: String,
  from: Option(Date),
  to: Option(Date),
) -> Builder {
  builder
  |> date_bound(column, ">=", from)
  |> date_bound(column, "<=", to)
}

fn date_bound(
  builder: Builder,
  column: String,
  op: String,
  value: Option(Date),
) -> Builder {
  case value {
    None -> builder
    Some(date) -> {
      let #(builder, placeholder) = bind(builder, pog.calendar_date(date))
      condition(builder, column <> " " <> op <> " " <> placeholder <> "::date")
    }
  }
}

/// Binds the page size and offset, returning the trailing `LIMIT/OFFSET` SQL. Call
/// last, so these params land after every filter param.
pub fn limit_offset(
  builder: Builder,
  limit: Int,
  offset: Int,
) -> #(Builder, String) {
  let #(builder, limit_placeholder) = bind(builder, pog.int(limit))
  let #(builder, offset_placeholder) = bind(builder, pog.int(offset))
  #(builder, " LIMIT " <> limit_placeholder <> " OFFSET " <> offset_placeholder)
}

/// `ORDER BY <resolved column> <ASC|DESC>, <tiebreak>`. `resolve` maps the request's
/// sort key to a trusted column literal (its own allowlist + default), so an unknown
/// or hostile key never reaches the SQL; direction is mapped to literal `ASC`/`DESC`.
pub fn order_by(
  sort: Option(Sort),
  default_key: String,
  resolve: fn(String) -> String,
  tiebreak: String,
) -> String {
  let #(key, dir) = case sort {
    Some(Sort(key:, dir:)) -> #(key, sort.dir_to_string(dir))
    None -> #(default_key, "desc")
  }
  let direction = case dir {
    "asc" -> "ASC"
    _ -> "DESC"
  }
  " ORDER BY " <> resolve(key) <> " " <> direction <> ", " <> tiebreak
}

// --- filter extraction ------------------------------------------------------

/// The selected values of a multi-select filter, or `None` when absent or empty.
pub fn select_values(
  filters: Dict(String, FilterValue),
  key: String,
) -> Option(List(String)) {
  case dict.get(filters, key) {
    Ok(SelectValue([])) -> None
    Ok(SelectValue(values)) -> Some(values)
    _ -> None
  }
}

/// The `#(min, max)` bounds of a number-range filter, each `None` when unset.
pub fn number_range_of(
  filters: Dict(String, FilterValue),
  key: String,
) -> #(Option(Float), Option(Float)) {
  case dict.get(filters, key) {
    Ok(NumberRange(min:, max:)) -> #(min, max)
    _ -> #(None, None)
  }
}

/// The `#(from, to)` bounds of a date-range filter, each `None` when unset or
/// unparseable.
pub fn date_range_of(
  filters: Dict(String, FilterValue),
  key: String,
) -> #(Option(Date), Option(Date)) {
  case dict.get(filters, key) {
    Ok(DateRange(from:, to:)) -> #(parse_date(from), parse_date(to))
    _ -> #(None, None)
  }
}

fn parse_date(text: Option(String)) -> Option(Date) {
  case text {
    Some(value) -> option.from_result(wire.parse_iso_date(value))
    None -> None
  }
}

// --- internal ---------------------------------------------------------------

fn text_array(values: List(String)) -> pog.Value {
  pog.array(pog.text, values)
}
