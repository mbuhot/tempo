//// Contract codecs for the data-table system: the schema, filter kinds, sort,
//// type-directed cells, the response envelope, and the applied query-param mapping.
//// Each round-trips through JSON to prove the wire shape, and the cell tests prove a
//// cell decodes correctly when directed by its column's type.

import gleam/dict
import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import gleam/list
import gleam/option.{None, Some}
import shared/money
import shared/table/cell.{Chip, ChipsCell, EnumCell, MoneyCell, TextCell}
import shared/table/column.{
  ChipsType, Column, EnumType, MoneyType, NumericEnd, Positive, Schema,
  StandaloneFilter, Start, TextType,
}
import shared/table/filter.{
  DateRangeFilter, FilterOption, NumberRangeFilter, SelectFilter,
}
import shared/table/query.{Applied, NumberRange, SelectValue}
import shared/table/response.{Page, Row, TableResponse}
import shared/table/sort.{Asc, Desc, Sort}

fn render(value: Json) -> String {
  json.to_string(value)
}

fn parse_with(
  text: String,
  decoder: Decoder(a),
) -> Result(a, json.DecodeError) {
  json.parse(text, decoder)
}

pub fn schema_round_trips_test() {
  let schema =
    Schema(
      table_id: "invoices",
      child_columns: None,
      columns: [
        Column(
          key: "client",
          label: "Client",
          column_type: TextType,
          align: Start,
          sortable: True,
          hideable: True,
          filter: None,
        ),
        Column(
          key: "total",
          label: "Total",
          column_type: MoneyType,
          align: NumericEnd,
          sortable: True,
          hideable: False,
          filter: Some(NumberRangeFilter),
        ),
      ],
      filters: [],
      default_sort: Some(Sort(key: "total", dir: Desc)),
    )
  let assert Ok(decoded) =
    parse_with(render(column.encode_schema(schema)), column.schema_decoder())
  assert decoded == schema
}

pub fn schema_level_filters_round_trip_test() {
  let schema =
    Schema(
      table_id: "events",
      child_columns: None,
      columns: [
        Column(
          key: "summary",
          label: "Event",
          column_type: TextType,
          align: Start,
          sortable: False,
          hideable: False,
          filter: None,
        ),
      ],
      filters: [
        StandaloneFilter(
          key: "operation",
          label: "Operation",
          kind: SelectFilter(
            options: [
              FilterOption(value: "issue_invoice", label: "issue_invoice"),
            ],
            multi: False,
          ),
        ),
        StandaloneFilter(
          key: "occurred",
          label: "Recorded",
          kind: DateRangeFilter(options: []),
        ),
      ],
      default_sort: None,
    )
  let assert Ok(decoded) =
    parse_with(render(column.encode_schema(schema)), column.schema_decoder())
  assert decoded == schema
  assert decoded.filters == schema.filters
}

pub fn schema_without_filters_field_still_decodes_test() {
  let legacy = "{\"table_id\":\"t\",\"columns\":[],\"default_sort\":null}"
  let assert Ok(decoded) = parse_with(legacy, column.schema_decoder())
  assert decoded.filters == []
}

pub fn select_filter_round_trips_test() {
  let kind =
    SelectFilter(
      options: [
        FilterOption(value: "draft", label: "Draft"),
        FilterOption(value: "paid", label: "Paid"),
      ],
      multi: True,
    )
  let assert Ok(decoded) =
    parse_with(
      render(filter.encode_filter_kind(kind)),
      filter.filter_kind_decoder(),
    )
  assert decoded == kind
}

pub fn sort_round_trips_test() {
  let value = Sort(key: "billing_month", dir: Asc)
  let assert Ok(decoded) =
    parse_with(render(sort.encode_sort(value)), sort.sort_decoder())
  assert decoded == value
}

pub fn money_cell_decodes_by_column_type_test() {
  let assert Ok(amount) = money.from_string("90100.00")
  let assert Ok(decoded) =
    parse_with(
      render(cell.encode_cell(MoneyCell(amount))),
      cell.cell_decoder(of: MoneyType),
    )
  assert decoded == MoneyCell(amount)
}

pub fn enum_cell_carries_tone_test() {
  let value = EnumCell(label: "Paid", tone: Positive)
  let assert Ok(decoded) =
    parse_with(render(cell.encode_cell(value)), cell.cell_decoder(of: EnumType))
  assert decoded == value
}

pub fn chips_cell_round_trips_test() {
  let value =
    ChipsCell([Chip(label: "Ana Ortiz", initials: Some("AO"), color: None)])
  let assert Ok(decoded) =
    parse_with(
      render(cell.encode_cell(value)),
      cell.cell_decoder(of: ChipsType),
    )
  assert decoded == value
}

pub fn response_round_trips_via_schema_test() {
  let schema =
    Schema(
      table_id: "t",
      child_columns: None,
      columns: [
        Column(
          key: "name",
          label: "Name",
          column_type: TextType,
          align: Start,
          sortable: False,
          hideable: True,
          filter: None,
        ),
      ],
      filters: [],
      default_sort: None,
    )
  let child =
    Row(
      id: "1.1",
      cells: dict.from_list([#("name", TextCell("Ana · L4"))]),
      children: [],
      detail: None,
    )
  let row =
    Row(
      id: "1",
      cells: dict.from_list([#("name", TextCell("Ana"))]),
      children: [child],
      detail: None,
    )
  let value =
    TableResponse(schema:, rows: [row], page: Page(next_cursor: Some("abc")))
  let assert Ok(decoded) =
    parse_with(
      render(response.encode_response(value)),
      response.response_decoder(),
    )
  assert decoded == value
}

pub fn applied_to_params_test() {
  let applied =
    Applied(
      filters: dict.from_list([
        #("status", SelectValue(["draft", "issued"])),
        #("total", NumberRange(min: Some(50_000.0), max: None)),
      ]),
      sort: Some(Sort(key: "total", dir: Desc)),
      page_size: 15,
      cursor: None,
    )
  let params = query.to_params(applied)
  assert list.contains(params, #("filter.status", "draft,issued"))
  assert list.contains(params, #("filter.total.min", "50000"))
  assert list.contains(params, #("sort", "total:desc"))
  assert list.contains(params, #("page_size", "15"))
}
