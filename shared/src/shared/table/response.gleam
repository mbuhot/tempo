//// The list-response envelope: the `schema` that drives the table, the `rows`, and
//// the `page` cursor. Rows decode against the schema — each cell is decoded by its
//// column's type — so a cell carries no redundant type tag on the wire.

import gleam/dict.{type Dict}
import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None}
import shared/pagination
import shared/table/cell.{type Cell}
import shared/table/column.{type Column, type Schema}

pub type Page {
  Page(next_cursor: Option(String))
}

/// One table row: its stable `id`, its `cells` keyed by column, any nested
/// `children` rows, and an optional full-width `detail` panel (pre-formatted text,
/// e.g. a JSON payload). A row is expandable when it has non-empty `children` OR a
/// `Some(detail)`; children are one level deep and carry no children of their own.
pub type Row {
  Row(
    id: String,
    cells: Dict(String, Cell),
    children: List(Row),
    detail: Option(String),
  )
}

/// A table summary row rendered in the `<tfoot>`: a leading `label` for the first
/// column (which the footer never carries a typed cell for) and typed `cells` keyed
/// by column for the numeric columns, decoded and rendered by the SAME path as a
/// body row's cells so the formatting matches exactly.
pub type Footer {
  Footer(label: String, cells: Dict(String, Cell))
}

pub type TableResponse {
  TableResponse(
    schema: Schema,
    rows: List(Row),
    page: Page,
    footer: Option(Footer),
  )
}

pub fn encode_response(value: TableResponse) -> Json {
  json.object([
    #("schema", column.encode_schema(value.schema)),
    #("rows", json.array(value.rows, encode_row)),
    #("page", encode_page(value.page)),
    #("footer", json.nullable(value.footer, encode_footer)),
  ])
}

fn encode_footer(footer: Footer) -> Json {
  json.object([
    #("label", json.string(footer.label)),
    #(
      "cells",
      json.object(
        dict.to_list(footer.cells)
        |> list.map(fn(pair) { #(pair.0, cell.encode_cell(pair.1)) }),
      ),
    ),
  ])
}

fn encode_row(row: Row) -> Json {
  json.object([
    #("id", json.string(row.id)),
    #(
      "cells",
      json.object(
        dict.to_list(row.cells)
        |> list.map(fn(pair) { #(pair.0, cell.encode_cell(pair.1)) }),
      ),
    ),
    #("children", json.array(row.children, encode_row)),
    #("detail", json.nullable(row.detail, json.string)),
  ])
}

fn encode_page(page: Page) -> Json {
  json.object([
    #("next_cursor", pagination.encode_next_cursor(page.next_cursor)),
  ])
}

pub fn response_decoder() -> Decoder(TableResponse) {
  use schema <- decode.field("schema", column.schema_decoder())
  let child_columns = option.unwrap(schema.child_columns, schema.columns)
  use rows <- decode.field(
    "rows",
    decode.list(row_decoder(schema.columns, child_columns)),
  )
  use page <- decode.field("page", page_decoder())
  use footer <- decode.optional_field(
    "footer",
    None,
    decode.optional(footer_decoder(schema.columns)),
  )
  decode.success(TableResponse(schema:, rows:, page:, footer:))
}

fn footer_decoder(columns: List(Column)) -> Decoder(Footer) {
  use label <- decode.field("label", decode.string)
  use cells <- decode.field("cells", footer_cells_decoder(columns))
  decode.success(Footer(label:, cells:))
}

/// A LENIENT cells decoder: each column's cell is OPTIONAL, so the footer may omit
/// columns (e.g. the leading month column it carries a `label` for). A cell is
/// inserted only when its column key is present in the JSON.
fn footer_cells_decoder(columns: List(Column)) -> Decoder(Dict(String, Cell)) {
  list.fold(columns, decode.success(dict.new()), fn(acc, column) {
    use so_far <- decode.then(acc)
    use updated <- decode.optional_field(
      column.key,
      so_far,
      decode.map(cell.cell_decoder(of: column.column_type), fn(value) {
        dict.insert(so_far, column.key, value)
      }),
    )
    decode.success(updated)
  })
}

fn row_decoder(
  own_columns: List(Column),
  child_columns: List(Column),
) -> Decoder(Row) {
  use id <- decode.field("id", decode.string)
  use cells <- decode.field("cells", cells_decoder(own_columns))
  use children <- decode.optional_field(
    "children",
    [],
    decode.list(row_decoder(child_columns, child_columns)),
  )
  use detail <- decode.optional_field(
    "detail",
    None,
    decode.optional(decode.string),
  )
  decode.success(Row(id:, cells:, children:, detail:))
}

fn cells_decoder(columns: List(Column)) -> Decoder(Dict(String, Cell)) {
  list.fold(columns, decode.success(dict.new()), fn(acc, column) {
    use so_far <- decode.then(acc)
    use value <- decode.field(
      column.key,
      cell.cell_decoder(of: column.column_type),
    )
    decode.success(dict.insert(so_far, column.key, value))
  })
}

fn page_decoder() -> Decoder(Page) {
  use next_cursor <- decode.field(
    "next_cursor",
    pagination.next_cursor_decoder(),
  )
  decode.success(Page(next_cursor:))
}
