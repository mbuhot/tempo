//// The applied filter/sort/page state, and its mapping to and from the URL query
//// params both ends share. The client builds `Applied` from the table state and
//// `to_params` turns it into the query string; the server reads the same param
//// names back via `parse_*` to drive the SQL. Param scheme: `filter.<key>` (csv for
//// select, substring for text, `true`/`false` for bool), `filter.<key>.min`/`.max`,
//// `filter.<key>.from`/`.to`, `sort=<key>:<dir>`, `page_size`, `cursor`.

import gleam/dict.{type Dict}
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import shared/table/column.{type Schema}
import shared/table/filter
import shared/table/sort.{type Sort, Sort}

pub type FilterValue {
  SelectValue(List(String))
  NumberRange(min: Option(Float), max: Option(Float))
  DateRange(from: Option(String), to: Option(String))
  TextValue(String)
  BoolValue(Bool)
}

pub type Applied {
  Applied(
    filters: Dict(String, FilterValue),
    sort: Option(Sort),
    page_size: Int,
    cursor: Option(String),
  )
}

/// Render the applied state as query-param pairs for the request URL. Empty filters
/// are dropped (a cleared filter produces no param).
pub fn to_params(applied: Applied) -> List(#(String, String)) {
  let filter_params =
    dict.to_list(applied.filters)
    |> list.flat_map(fn(pair) { filter_to_params(pair.0, pair.1) })
  let sort_params = case applied.sort {
    Some(Sort(key:, dir:)) -> [#("sort", key <> ":" <> sort.dir_to_string(dir))]
    None -> []
  }
  let cursor_params = case applied.cursor {
    Some(cursor) -> [#("cursor", cursor)]
    None -> []
  }
  list.flatten([
    filter_params,
    sort_params,
    [#("page_size", int.to_string(applied.page_size))],
    cursor_params,
  ])
}

fn filter_to_params(
  key: String,
  value: FilterValue,
) -> List(#(String, String)) {
  case value {
    SelectValue([]) -> []
    SelectValue(values) -> [#("filter." <> key, string.join(values, ","))]
    TextValue("") -> []
    TextValue(text) -> [#("filter." <> key, text)]
    BoolValue(yes) -> [#("filter." <> key, bool_to_string(yes))]
    NumberRange(min:, max:) ->
      list.flatten([
        maybe_param("filter." <> key <> ".min", option.map(min, float_param)),
        maybe_param("filter." <> key <> ".max", option.map(max, float_param)),
      ])
    DateRange(from:, to:) ->
      list.flatten([
        maybe_param("filter." <> key <> ".from", from),
        maybe_param("filter." <> key <> ".to", to),
      ])
  }
}

fn maybe_param(name: String, value: Option(String)) -> List(#(String, String)) {
  case value {
    Some(text) -> [#(name, text)]
    None -> []
  }
}

fn bool_to_string(yes: Bool) -> String {
  case yes {
    True -> "true"
    False -> "false"
  }
}

/// Render a filter bound without scientific notation: a whole amount as a plain
/// integer (`50000`), a fractional amount via the float formatter (`48250.5`), so
/// the value re-parses and reads as a PostgreSQL numeric.
fn float_param(value: Float) -> String {
  let whole = float.truncate(value)
  case int.to_float(whole) == value {
    True -> int.to_string(whole)
    False -> float.to_string(value)
  }
}

/// Build the applied state from request params + the table schema (server side). The
/// schema tells `parse_filters` which columns are filterable and with what kind.
pub fn from_params(
  params: List(#(String, String)),
  schema: Schema,
  default_page_size: Int,
) -> Applied {
  Applied(
    filters: parse_filters(params, schema),
    sort: parse_sort(params),
    page_size: parse_page_size(params, default_page_size),
    cursor: get(params, "cursor"),
  )
}

/// Read the applied filter for each filterable column, by the same param names
/// `to_params` writes.
pub fn parse_filters(
  params: List(#(String, String)),
  schema: Schema,
) -> Dict(String, FilterValue) {
  list.fold(schema.columns, dict.new(), fn(acc, column) {
    case column.filter {
      None -> acc
      Some(kind) ->
        case parse_one(params, column.key, kind) {
          Some(value) -> dict.insert(acc, column.key, value)
          None -> acc
        }
    }
  })
}

fn parse_one(
  params: List(#(String, String)),
  key: String,
  kind: filter.FilterKind,
) -> Option(FilterValue) {
  case kind {
    filter.TextFilter -> option.map(get(params, "filter." <> key), TextValue)
    filter.SelectFilter(..) ->
      case get(params, "filter." <> key) {
        Some(csv) -> Some(SelectValue(string.split(csv, ",")))
        None -> None
      }
    filter.NumberRangeFilter -> {
      let min =
        get(params, "filter." <> key <> ".min") |> option.then(parse_float)
      let max =
        get(params, "filter." <> key <> ".max") |> option.then(parse_float)
      case min, max {
        None, None -> None
        _, _ -> Some(NumberRange(min:, max:))
      }
    }
    filter.DateRangeFilter(..) -> {
      let from = get(params, "filter." <> key <> ".from")
      let to = get(params, "filter." <> key <> ".to")
      case from, to {
        None, None -> None
        _, _ -> Some(DateRange(from:, to:))
      }
    }
    filter.BoolFilter ->
      case get(params, "filter." <> key) {
        Some("true") -> Some(BoolValue(True))
        Some("false") -> Some(BoolValue(False))
        _ -> None
      }
  }
}

/// Read `sort=<key>:<dir>` into a `Sort`, or `None` when absent or malformed.
pub fn parse_sort(params: List(#(String, String))) -> Option(Sort) {
  case get(params, "sort") {
    None -> None
    Some(text) ->
      case string.split_once(text, ":") {
        Ok(#(key, dir_text)) ->
          case sort.dir_from_string(dir_text) {
            Ok(dir) -> Some(Sort(key:, dir:))
            Error(Nil) -> None
          }
        Error(Nil) -> None
      }
  }
}

fn parse_page_size(params: List(#(String, String)), fallback: Int) -> Int {
  case get(params, "page_size") |> option.then(parse_int) {
    Some(size) -> size
    None -> fallback
  }
}

fn get(params: List(#(String, String)), name: String) -> Option(String) {
  case list.key_find(params, name) {
    Ok("") -> None
    Ok(value) -> Some(value)
    Error(Nil) -> None
  }
}

fn parse_float(text: String) -> Option(Float) {
  option.from_result(float.parse(text))
}

fn parse_int(text: String) -> Option(Int) {
  option.from_result(int.parse(text))
}
