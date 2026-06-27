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

pub type TableResponse {
  TableResponse(schema: Schema, rows: List(Row), page: Page)
}

pub fn encode_response(value: TableResponse) -> Json {
  json.object([
    #("schema", column.encode_schema(value.schema)),
    #("rows", json.array(value.rows, encode_row)),
    #("page", encode_page(value.page)),
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
  use rows <- decode.field("rows", decode.list(row_decoder(schema.columns)))
  use page <- decode.field("page", page_decoder())
  decode.success(TableResponse(schema:, rows:, page:))
}

fn row_decoder(columns: List(Column)) -> Decoder(Row) {
  use id <- decode.field("id", decode.string)
  use cells <- decode.field("cells", cells_decoder(columns))
  use children <- decode.optional_field(
    "children",
    [],
    decode.list(row_decoder(columns)),
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
