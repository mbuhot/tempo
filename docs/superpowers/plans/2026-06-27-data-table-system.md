# Data Table System Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A generic, server-driven data table — schema-advertised filters/sorts, keyset-style pagination, and local column reorder/hide — proven on the Invoices list.

**Architecture:** A new `shared/table/` concept holds the wire contract: a `ColumnType` union and a parallel `Cell` union (cells travel untagged, decoded by column type), plus `FilterKind`, `Schema`, `Sort`, and a `TableResponse` envelope. The server builds a static `Schema` per list and applies filters/sort/pagination in one static Squirrel query using the `(param IS NULL OR col matches param)` null-guard idiom; sort is a `CASE`-driven `ORDER BY`; pagination is an opaque cursor that currently encodes an offset (so true keyset can replace it later with no wire change). The client owns one reusable `client/table` MVU unit with renderer + filter-widget registries selected by exhaustive `case` (no `_`), so a new column type fails the build until handled.

**Tech Stack:** Gleam (shared/server/client), Lustre (client MVU), Squirrel (compile-time typed SQL via `bin/squirrel`), pog/PostgreSQL, Sass (`client/styles/*.scss`), Playwright (e2e under `e2e/`).

## Global Constraints

- Gleam style: `let assert Ok(...)` unwrap; `todo` for stubs; tests use `assert expr == expected` (no gleeunit `should`); separate parse from solve; SLAP; read 2-3 sibling files before creating one.
- No inline comments inside functions anywhere (tests included); only `////` module / `///` public-decl doc comments, terse, one line. No counterfactual ("X not Y") comments.
- Organize by domain concept; CQRS keeps read/query and command sides in separate files. Every `shared/<x>/command` or `/view` binds the same default qualifier — alias on import collision.
- Exhaustiveness is load-bearing: every `case` over `ColumnType`, `Cell`, `FilterKind`, `Tone` has **no `_` arm**. This is the build-time safety contract.
- Money is `shared/money.Money` (read `numeric::text`, write `$N::text::numeric`); ratios stay `Float`.
- `gleam test` runs on the base seed (0 invoices). Server table tests **insert their own invoices in a rolled-back transaction fixture** (the `financials_test.gleam` `rolling_back` pattern); never depend on the demo seed.
- Squirrel regenerates `sql.gleam` from `.sql` via `bin/squirrel` against a live DB (`bin/db && bin/migrate` first). One `sql.gleam` per directory; invoice SQL lives in `server/src/tempo/server/invoice/sql/*.sql`.
- Build the client with `bin/build`; full check is `bin/test` (gleam test + `gleam format --check` + `bin/lint-css`). CSS: no literal hex/size, no `--` decls outside `theme.scss`; recurring clusters use `_mixins.scss` mixins.
- Commit straight to `main`; list files explicitly when staging (no `git add -A`). Commit messages describe WHAT + approach; no Claude/Anthropic attribution.
- e2e financial reads need `read.finances`; sign in as Admin in the spec.

---

## File Structure

**Created — shared (`shared/src/shared/table/`):**
- `column.gleam` — `ColumnType`, `Tone`, `Align`, `Column`, `Schema` + codecs.
- `cell.gleam` — `Cell`, `Chip`, type-directed `cell_decoder(ColumnType)`, `encode_cell`.
- `filter.gleam` — `FilterKind`, `FilterOption` + codecs.
- `sort.gleam` — `Sort`, `SortDir` + codecs.
- `response.gleam` — `Page`, `Row`, `TableResponse` + schema-directed codecs.
- `query.gleam` — applied-filter/sort/page → query-param list (client encode) and parse (server decode).

**Created — server:**
- `server/src/tempo/server/invoice/sql/invoice_table.sql` — the filtered/sorted/paginated list query.
- `server/src/tempo/server/invoice/table.gleam` — schema builder, request→params, rows→cells, pagination.
- `server/test/table_test.gleam` — server filter/sort/pagination tests (rolled-back fixture).

**Created — client:**
- `client/src/client/storage.gleam` + `client/src/client/storage_ffi.mjs` — `localStorage` get/set effects.
- `client/src/client/table.gleam` — generic table MVU (`State`, `Msg`, `init`, `update`, `view`, `Outcome`).
- `client/styles/table.scss` — rail, popover, columns manager styles.

**Modified — server:**
- `server/src/tempo/server/invoice/http.gleam` — add `handle_table` for `GET /api/invoices/table`.
- `server/src/tempo/server/web/router.gleam` — route `["api","invoices","table"]`.
- `server/src/tempo/server/web/request.gleam` — `string_from_query`, `optional_floats`, multi-value helpers.

**Modified — client:**
- `client/src/client/page/finance/invoices.gleam` — render the list via `client/table`.
- `client/styles/main.scss` — `@use 'table'`.

**Created — tests:**
- `shared/test/table_test.gleam` — contract codecs + exhaustive decoder coverage.
- `e2e/finance-table.spec.js` — filter/sort/load-more/column-hide behaviour.

---

## Task 1: `shared/table/column.gleam` — column schema + codecs

**Files:**
- Create: `shared/src/shared/table/column.gleam`
- Test: `shared/test/table_test.gleam`

**Interfaces:**
- Produces: `ColumnType` (`TextType NumberType MoneyType DateType EnumType EntityType PersonType ChipsType BoolType`), `Tone` (`Neutral Accent Positive Warning Critical`), `Align` (`Start NumericEnd`), `Column(key label column_type align sortable hideable filter: Option(filter.FilterKind))`, `Schema(table_id columns default_sort: Option(sort.Sort))`. `encode_schema/1`, `schema_decoder/0`, `column_type_to_string/1`, `column_type_from_string/1`.

- [ ] **Step 1: Write the failing test** — append to `shared/test/table_test.gleam`:

```gleam
import gleam/option.{None, Some}
import shared/table/column.{
  Column, NumericEnd, Schema, Start, MoneyType, TextType,
}
import shared/table/filter
import shared/table/sort

pub fn schema_round_trips_test() {
  let schema =
    Schema(
      table_id: "invoices",
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
          filter: Some(filter.NumberRangeFilter),
        ),
      ],
      default_sort: Some(sort.Sort(key: "total", dir: sort.Desc)),
    )
  let json = column.encode_schema(schema) |> gleam_json_to_string
  let assert Ok(decoded) = parse_with(json, column.schema_decoder())
  assert decoded == schema
}
```

Add the small helpers `gleam_json_to_string` and `parse_with` once at the top of the test module (see existing `shared/test/shared_test.gleam` / `money_test.gleam` for the `json.to_string` + `json.parse(_, decoder)` idiom and copy that pattern).

- [ ] **Step 2: Run to verify it fails to compile (module missing)**

Run: `cd shared && gleam test`
Expected: compile error — `module shared/table/column not found`.

- [ ] **Step 3: Implement `column.gleam`**

```gleam
//// A table column's schema: its key, label, semantic data-type, alignment,
//// whether it sorts, whether it can be hidden, and (optionally) the filter the
//// server offers for it. The `ColumnType` union is the source of truth the client
//// switches on to render and decode; every `case` over it is exhaustive, so adding
//// a variant fails the build until each site handles it.

import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import gleam/option.{type Option}
import shared/table/filter.{type FilterKind}
import shared/table/sort.{type Sort}

pub type ColumnType {
  TextType
  NumberType
  MoneyType
  DateType
  EnumType
  EntityType
  PersonType
  ChipsType
  BoolType
}

pub type Tone {
  Neutral
  Accent
  Positive
  Warning
  Critical
}

pub type Align {
  Start
  NumericEnd
}

pub type Column {
  Column(
    key: String,
    label: String,
    column_type: ColumnType,
    align: Align,
    sortable: Bool,
    hideable: Bool,
    filter: Option(FilterKind),
  )
}

pub type Schema {
  Schema(table_id: String, columns: List(Column), default_sort: Option(Sort))
}

pub fn column_type_to_string(column_type: ColumnType) -> String {
  case column_type {
    TextType -> "text"
    NumberType -> "number"
    MoneyType -> "money"
    DateType -> "date"
    EnumType -> "enum"
    EntityType -> "entity"
    PersonType -> "person"
    ChipsType -> "chips"
    BoolType -> "bool"
  }
}

pub fn column_type_from_string(text: String) -> Result(ColumnType, Nil) {
  case text {
    "text" -> Ok(TextType)
    "number" -> Ok(NumberType)
    "money" -> Ok(MoneyType)
    "date" -> Ok(DateType)
    "enum" -> Ok(EnumType)
    "entity" -> Ok(EntityType)
    "person" -> Ok(PersonType)
    "chips" -> Ok(ChipsType)
    "bool" -> Ok(BoolType)
    _ -> Error(Nil)
  }
}

pub fn tone_to_string(tone: Tone) -> String {
  case tone {
    Neutral -> "neutral"
    Accent -> "accent"
    Positive -> "positive"
    Warning -> "warning"
    Critical -> "critical"
  }
}

pub fn tone_from_string(text: String) -> Result(Tone, Nil) {
  case text {
    "neutral" -> Ok(Neutral)
    "accent" -> Ok(Accent)
    "positive" -> Ok(Positive)
    "warning" -> Ok(Warning)
    "critical" -> Ok(Critical)
    _ -> Error(Nil)
  }
}

fn align_to_string(align: Align) -> String {
  case align {
    Start -> "start"
    NumericEnd -> "num"
  }
}

fn align_from_string(text: String) -> Align {
  case text {
    "num" -> NumericEnd
    _ -> Start
  }
}

pub fn encode_schema(schema: Schema) -> Json {
  json.object([
    #("table_id", json.string(schema.table_id)),
    #("columns", json.array(schema.columns, encode_column)),
    #("default_sort", json.nullable(schema.default_sort, sort.encode_sort)),
  ])
}

fn encode_column(column: Column) -> Json {
  json.object([
    #("key", json.string(column.key)),
    #("label", json.string(column.label)),
    #("type", json.string(column_type_to_string(column.column_type))),
    #("align", json.string(align_to_string(column.align))),
    #("sortable", json.bool(column.sortable)),
    #("hideable", json.bool(column.hideable)),
    #("filter", json.nullable(column.filter, filter.encode_filter_kind)),
  ])
}

pub fn schema_decoder() -> Decoder(Schema) {
  use table_id <- decode.field("table_id", decode.string)
  use columns <- decode.field("columns", decode.list(column_decoder()))
  use default_sort <- decode.field(
    "default_sort",
    decode.optional(sort.sort_decoder()),
  )
  decode.success(Schema(table_id:, columns:, default_sort:))
}

fn column_decoder() -> Decoder(Column) {
  use key <- decode.field("key", decode.string)
  use label <- decode.field("label", decode.string)
  use type_text <- decode.field("type", decode.string)
  use align_text <- decode.field("align", decode.string)
  use sortable <- decode.field("sortable", decode.bool)
  use hideable <- decode.field("hideable", decode.bool)
  use filter <- decode.field(
    "filter",
    decode.optional(filter.filter_kind_decoder()),
  )
  let column_type = case column_type_from_string(type_text) {
    Ok(value) -> value
    Error(Nil) -> TextType
  }
  decode.success(Column(
    key:,
    label:,
    column_type:,
    align: align_from_string(align_text),
    sortable:,
    hideable:,
    filter:,
  ))
}
```

- [ ] **Step 4: Run the test (depends on Tasks 2 & 3 modules existing).** Implement Tasks 2 and 3 first if the compiler reports `filter`/`sort` missing, then return here. Run: `cd shared && gleam test`. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add shared/src/shared/table/column.gleam shared/test/table_test.gleam
git commit -m "Add table column schema union + codecs (shared/table/column)"
```

---

## Task 2: `shared/table/filter.gleam` — filter kinds + codecs

**Files:**
- Create: `shared/src/shared/table/filter.gleam`
- Test: `shared/test/table_test.gleam`

**Interfaces:**
- Produces: `FilterKind` (`TextFilter SelectFilter(options: List(FilterOption), multi: Bool) NumberRangeFilter DateRangeFilter BoolFilter`), `FilterOption(value label)`, `encode_filter_kind/1`, `filter_kind_decoder/0`.

- [ ] **Step 1: Write the failing test** — add to `table_test.gleam`:

```gleam
import shared/table/filter.{FilterOption, SelectFilter}

pub fn select_filter_round_trips_test() {
  let kind =
    SelectFilter(
      options: [
        FilterOption(value: "draft", label: "Draft"),
        FilterOption(value: "paid", label: "Paid"),
      ],
      multi: True,
    )
  let json = filter.encode_filter_kind(kind) |> gleam_json_to_string
  let assert Ok(decoded) = parse_with(json, filter.filter_kind_decoder())
  assert decoded == kind
}
```

- [ ] **Step 2: Run to verify failure** — `cd shared && gleam test` → compile error, module missing.

- [ ] **Step 3: Implement `filter.gleam`**

```gleam
//// The filter a column offers, advertised by the server in the schema. The kind is
//// independent of the column's data-type: the server decides what it can filter.
//// `SelectFilter` carries server-supplied options, so data-driven option lists
//// (clients, projects, engineers) ship live.

import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}

pub type FilterKind {
  TextFilter
  SelectFilter(options: List(FilterOption), multi: Bool)
  NumberRangeFilter
  DateRangeFilter
  BoolFilter
}

pub type FilterOption {
  FilterOption(value: String, label: String)
}

pub fn encode_filter_kind(kind: FilterKind) -> Json {
  case kind {
    TextFilter -> json.object([#("kind", json.string("text"))])
    SelectFilter(options:, multi:) ->
      json.object([
        #("kind", json.string("select")),
        #("multi", json.bool(multi)),
        #("options", json.array(options, encode_option)),
      ])
    NumberRangeFilter -> json.object([#("kind", json.string("number_range"))])
    DateRangeFilter -> json.object([#("kind", json.string("date_range"))])
    BoolFilter -> json.object([#("kind", json.string("bool"))])
  }
}

fn encode_option(option: FilterOption) -> Json {
  json.object([
    #("value", json.string(option.value)),
    #("label", json.string(option.label)),
  ])
}

pub fn filter_kind_decoder() -> Decoder(FilterKind) {
  use kind <- decode.field("kind", decode.string)
  case kind {
    "text" -> decode.success(TextFilter)
    "number_range" -> decode.success(NumberRangeFilter)
    "date_range" -> decode.success(DateRangeFilter)
    "bool" -> decode.success(BoolFilter)
    "select" -> {
      use multi <- decode.field("multi", decode.bool)
      use options <- decode.field("options", decode.list(option_decoder()))
      decode.success(SelectFilter(options:, multi:))
    }
    _ -> decode.failure(TextFilter, "FilterKind")
  }
}

fn option_decoder() -> Decoder(FilterOption) {
  use value <- decode.field("value", decode.string)
  use label <- decode.field("label", decode.string)
  decode.success(FilterOption(value:, label:))
}
```

- [ ] **Step 4: Run** — `cd shared && gleam test` → PASS.
- [ ] **Step 5: Commit**

```bash
git add shared/src/shared/table/filter.gleam shared/test/table_test.gleam
git commit -m "Add table filter-kind union + codecs (shared/table/filter)"
```

---

## Task 3: `shared/table/sort.gleam` — sort spec + codecs

**Files:**
- Create: `shared/src/shared/table/sort.gleam`
- Test: `shared/test/table_test.gleam`

**Interfaces:**
- Produces: `Sort(key: String, dir: SortDir)`, `SortDir` (`Asc Desc`), `encode_sort/1`, `sort_decoder/0`, `dir_to_string/1`, `dir_from_string/1`.

- [ ] **Step 1: Write the failing test**

```gleam
import shared/table/sort.{Asc, Sort}

pub fn sort_round_trips_test() {
  let value = Sort(key: "billing_month", dir: Asc)
  let json = sort.encode_sort(value) |> gleam_json_to_string
  let assert Ok(decoded) = parse_with(json, sort.sort_decoder())
  assert decoded == value
}
```

- [ ] **Step 2: Run to verify failure.**
- [ ] **Step 3: Implement `sort.gleam`**

```gleam
//// A table's active (or default) sort: the column key and direction.

import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}

pub type SortDir {
  Asc
  Desc
}

pub type Sort {
  Sort(key: String, dir: SortDir)
}

pub fn dir_to_string(dir: SortDir) -> String {
  case dir {
    Asc -> "asc"
    Desc -> "desc"
  }
}

pub fn dir_from_string(text: String) -> Result(SortDir, Nil) {
  case text {
    "asc" -> Ok(Asc)
    "desc" -> Ok(Desc)
    _ -> Error(Nil)
  }
}

pub fn encode_sort(value: Sort) -> Json {
  json.object([
    #("key", json.string(value.key)),
    #("dir", json.string(dir_to_string(value.dir))),
  ])
}

pub fn sort_decoder() -> Decoder(Sort) {
  use key <- decode.field("key", decode.string)
  use dir_text <- decode.field("dir", decode.string)
  let dir = case dir_from_string(dir_text) {
    Ok(value) -> value
    Error(Nil) -> Asc
  }
  decode.success(Sort(key:, dir:))
}
```

- [ ] **Step 4: Run** — `cd shared && gleam test` → PASS (Tasks 1-3 now compile together).
- [ ] **Step 5: Commit**

```bash
git add shared/src/shared/table/sort.gleam shared/test/table_test.gleam
git commit -m "Add table sort spec + codecs (shared/table/sort)"
```

---

## Task 4: `shared/table/cell.gleam` — typed cell union + type-directed codec

**Files:**
- Create: `shared/src/shared/table/cell.gleam`
- Test: `shared/test/table_test.gleam`

**Interfaces:**
- Consumes: `column.ColumnType`, `column.Tone`, `money.Money`, `wire` date codecs.
- Produces: `Cell` (`TextCell(String) NumberCell(Float) MoneyCell(Money) DateCell(Date) EnumCell(label: String, tone: Tone) EntityCell(label: String, color: String) PersonCell(name sub: Option(String) initials color) ChipsCell(List(Chip)) BoolCell(Bool)`), `Chip(label initials: Option(String) color: Option(String))`, `encode_cell/1`, `cell_decoder(of: ColumnType) -> Decoder(Cell)`.

This is exhaustiveness site #1 (`cell_decoder` on `ColumnType`) and #2 (`encode_cell` on `Cell`).

- [ ] **Step 1: Write the failing tests** — cover the type-directed decode for each type plus encode round-trip:

```gleam
import gleam/time/calendar.{Date, January}
import shared/money
import shared/table/cell.{
  Chip, ChipsCell, DateCell, EntityCell, EnumCell, MoneyCell, NumberCell,
  PersonCell, TextCell,
}
import shared/table/column.{
  ChipsType, DateType, EntityType, EnumType, MoneyType, NumberType, PersonType,
  Positive, TextType,
}

pub fn money_cell_decodes_by_column_type_test() {
  let assert Ok(amount) = money.from_string("90100.00")
  let json = cell.encode_cell(MoneyCell(amount)) |> gleam_json_to_string
  let assert Ok(decoded) = parse_with(json, cell.cell_decoder(of: MoneyType))
  assert decoded == MoneyCell(amount)
}

pub fn enum_cell_carries_tone_test() {
  let json =
    cell.encode_cell(EnumCell(label: "Paid", tone: Positive))
    |> gleam_json_to_string
  let assert Ok(decoded) = parse_with(json, cell.cell_decoder(of: EnumType))
  assert decoded == EnumCell(label: "Paid", tone: Positive)
}

pub fn chips_cell_round_trips_test() {
  let chips = [
    Chip(label: "Ana Ortiz", initials: option.Some("AO"), color: option.None),
  ]
  let json = cell.encode_cell(ChipsCell(chips)) |> gleam_json_to_string
  let assert Ok(decoded) = parse_with(json, cell.cell_decoder(of: ChipsType))
  assert decoded == ChipsCell(chips)
}
```

- [ ] **Step 2: Run to verify failure** — module missing.

- [ ] **Step 3: Implement `cell.gleam`** — the decoder switches on `ColumnType` with no `_`; encode switches on `Cell` with no `_`:

```gleam
//// A table cell's value. Cells travel UNTAGGED on the wire — the column's
//// `ColumnType` directs `cell_decoder` to the right variant, so the type lives once
//// on the column. The `Cell` union mirrors `ColumnType`; both `cell_decoder` (on
//// `ColumnType`) and `encode_cell` (on `Cell`) are exhaustive, keeping the two in
//// lockstep at build time.

import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import gleam/option.{type Option}
import gleam/time/calendar.{type Date}
import shared/money.{type Money}
import shared/table/column.{
  type ColumnType, type Tone, BoolType, ChipsType, DateType, EntityType,
  EnumType, MoneyType, Neutral, NumberType, PersonType, TextType,
}
import shared/wire

pub type Cell {
  TextCell(String)
  NumberCell(Float)
  MoneyCell(Money)
  DateCell(Date)
  EnumCell(label: String, tone: Tone)
  EntityCell(label: String, color: String)
  PersonCell(name: String, sub: Option(String), initials: String, color: String)
  ChipsCell(List(Chip))
  BoolCell(Bool)
}

pub type Chip {
  Chip(label: String, initials: Option(String), color: Option(String))
}

pub fn encode_cell(cell: Cell) -> Json {
  case cell {
    TextCell(value) -> json.string(value)
    NumberCell(value) -> json.float(value)
    MoneyCell(value) -> money.encode(value)
    DateCell(value) -> wire.encode_date(value)
    EnumCell(label:, tone:) ->
      json.object([
        #("label", json.string(label)),
        #("tone", json.string(column.tone_to_string(tone))),
      ])
    EntityCell(label:, color:) ->
      json.object([
        #("label", json.string(label)),
        #("color", json.string(color)),
      ])
    PersonCell(name:, sub:, initials:, color:) ->
      json.object([
        #("name", json.string(name)),
        #("sub", json.nullable(sub, json.string)),
        #("initials", json.string(initials)),
        #("color", json.string(color)),
      ])
    ChipsCell(chips) -> json.array(chips, encode_chip)
    BoolCell(value) -> json.bool(value)
  }
}

fn encode_chip(chip: Chip) -> Json {
  json.object([
    #("label", json.string(chip.label)),
    #("initials", json.nullable(chip.initials, json.string)),
    #("color", json.nullable(chip.color, json.string)),
  ])
}

pub fn cell_decoder(of column_type: ColumnType) -> Decoder(Cell) {
  case column_type {
    TextType -> decode.map(decode.string, TextCell)
    NumberType -> decode.map(decode.float, NumberCell)
    MoneyType -> decode.map(money.decoder(), MoneyCell)
    DateType -> decode.map(wire.date_decoder(), DateCell)
    BoolType -> decode.map(decode.bool, BoolCell)
    EnumType -> enum_decoder()
    EntityType -> entity_decoder()
    PersonType -> person_decoder()
    ChipsType -> decode.map(decode.list(chip_decoder()), ChipsCell)
  }
}

fn enum_decoder() -> Decoder(Cell) {
  use label <- decode.field("label", decode.string)
  use tone_text <- decode.field("tone", decode.string)
  let tone = case column.tone_from_string(tone_text) {
    Ok(value) -> value
    Error(Nil) -> Neutral
  }
  decode.success(EnumCell(label:, tone:))
}

fn entity_decoder() -> Decoder(Cell) {
  use label <- decode.field("label", decode.string)
  use color <- decode.field("color", decode.string)
  decode.success(EntityCell(label:, color:))
}

fn person_decoder() -> Decoder(Cell) {
  use name <- decode.field("name", decode.string)
  use sub <- decode.field("sub", decode.optional(decode.string))
  use initials <- decode.field("initials", decode.string)
  use color <- decode.field("color", decode.string)
  decode.success(PersonCell(name:, sub:, initials:, color:))
}

fn chip_decoder() -> Decoder(Chip) {
  use label <- decode.field("label", decode.string)
  use initials <- decode.field("initials", decode.optional(decode.string))
  use color <- decode.field("color", decode.optional(decode.string))
  decode.success(Chip(label:, initials:, color:))
}
```

- [ ] **Step 4: Run** — `cd shared && gleam test` → PASS. Confirm `wire.encode_date`/`wire.date_decoder` names against `shared/src/shared/wire.gleam` before running; adjust if the helpers are named differently.
- [ ] **Step 5: Commit**

```bash
git add shared/src/shared/table/cell.gleam shared/test/table_test.gleam
git commit -m "Add typed Cell union + type-directed cell codec (shared/table/cell)"
```

---

## Task 5: `shared/table/response.gleam` — envelope + schema-directed row decode

**Files:**
- Create: `shared/src/shared/table/response.gleam`
- Test: `shared/test/table_test.gleam`

**Interfaces:**
- Consumes: `column.Schema`, `column.Column`, `cell.Cell`, `cell.cell_decoder`, `pagination`.
- Produces: `Page(next_cursor: Option(String))`, `Row(id: String, cells: Dict(String, Cell))`, `TableResponse(schema: Schema, rows: List(Row), page: Page)`, `encode_response/1`, `response_decoder/0`. The row decoder reads the schema first, then decodes each row's `cells` object field-by-field using `cell_decoder(column.column_type)`.

- [ ] **Step 1: Write the failing test** — build a one-column schema + one row, round-trip:

```gleam
import gleam/dict
import shared/table/response.{Page, Row, TableResponse}

pub fn response_round_trips_via_schema_test() {
  let schema =
    Schema(
      table_id: "t",
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
      default_sort: None,
    )
  let row = Row(id: "1", cells: dict.from_list([#("name", TextCell("Ana"))]))
  let value =
    TableResponse(schema:, rows: [row], page: Page(next_cursor: Some("abc")))
  let json = response.encode_response(value) |> gleam_json_to_string
  let assert Ok(decoded) = parse_with(json, response.response_decoder())
  assert decoded == value
}
```

- [ ] **Step 2: Run to verify failure.**

- [ ] **Step 3: Implement `response.gleam`** — note the row decoder is built AFTER the schema is known, so it can pick the per-column cell decoder. Use `decode.then` to thread the schema into the rows decoder:

```gleam
//// The list-response envelope: the `schema` that drives the table, the `rows`, and
//// the `page` cursor. Rows decode against the schema — each cell is decoded by its
//// column's type — so a cell carries no redundant type tag on the wire.

import gleam/dict.{type Dict}
import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option}
import shared/pagination
import shared/table/cell.{type Cell}
import shared/table/column.{type Column, type Schema}

pub type Page {
  Page(next_cursor: Option(String))
}

pub type Row {
  Row(id: String, cells: Dict(String, Cell))
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
  ])
}

fn encode_page(page: Page) -> Json {
  json.object([#("next_cursor", pagination.encode_next_cursor(page.next_cursor))])
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
  decode.success(Row(id:, cells:))
}

fn cells_decoder(columns: List(Column)) -> Decoder(Dict(String, Cell)) {
  list.fold(columns, decode.success(dict.new()), fn(acc, column) {
    use so_far <- decode.then(acc)
    use value <- decode.field(column.key, cell.cell_decoder(of: column.column_type))
    decode.success(dict.insert(so_far, column.key, value))
  })
}

fn page_decoder() -> Decoder(Page) {
  use next_cursor <- decode.field("next_cursor", pagination.next_cursor_decoder())
  decode.success(Page(next_cursor:))
}
```

If `decode.then` is unavailable in the pinned stdlib, fold using `decode.field` inside a manually-threaded decoder — verify the available combinators in `shared/build/packages/gleam_stdlib/src/gleam/dynamic/decode.gleam` and adapt.

- [ ] **Step 4: Run** — `cd shared && gleam test` → PASS.
- [ ] **Step 5: Commit**

```bash
git add shared/src/shared/table/response.gleam shared/test/table_test.gleam
git commit -m "Add TableResponse envelope with schema-directed row decode"
```

---

## Task 6: `shared/table/query.gleam` — applied filter/sort/page query params

**Files:**
- Create: `shared/src/shared/table/query.gleam`
- Test: `shared/test/table_test.gleam`

**Interfaces:**
- Produces:
  - `Applied(filters: Dict(String, FilterValue), sort: Option(Sort), page_size: Int, cursor: Option(String))`
  - `FilterValue` (`SelectValue(List(String)) NumberRange(min: Option(Float), max: Option(Float)) DateRange(from: Option(String), to: Option(String)) TextValue(String) BoolValue(Bool)`)
  - `to_params(Applied) -> List(#(String, String))` (client → query string; used to build the URL)
  - `param(name, params) -> Option(String)` helpers for the server to read them back.
- This module is shared so the client encodes and the server decodes the SAME param names. Param scheme (matches the spec): `filter.<key>` (csv for select, substring for text, `true`/`false` for bool), `filter.<key>.min`/`.max`, `filter.<key>.from`/`.to`, `sort=<key>:<dir>`, `page_size`, `cursor`.

- [ ] **Step 1: Write the failing test**

```gleam
import gleam/dict
import shared/table/query.{
  Applied, NumberRange, SelectValue,
}

pub fn applied_to_params_test() {
  let applied =
    Applied(
      filters: dict.from_list([
        #("status", SelectValue(["draft", "issued"])),
        #("total", NumberRange(min: Some(50000.0), max: None)),
      ]),
      sort: Some(sort.Sort(key: "total", dir: sort.Desc)),
      page_size: 15,
      cursor: None,
    )
  let params = query.to_params(applied)
  assert list.contains(params, #("filter.status", "draft,issued"))
  assert list.contains(params, #("filter.total.min", "50000.0"))
  assert list.contains(params, #("sort", "total:desc"))
  assert list.contains(params, #("page_size", "15"))
}
```

- [ ] **Step 2: Run to verify failure.**
- [ ] **Step 3: Implement `query.gleam`** — `to_params` folds the filter dict into the param pairs (csv-join select values with `,`; float via `float.to_string`; bool via `"true"`/`"false"`), appends `sort`, `page_size`, and `cursor` when present. Provide `parse_filters(params, schema) -> Dict(String, FilterValue)` for the server: for each column with a filter, read its params by the same names and build the matching `FilterValue`. Keep parse and build separate functions (SLAP). (Write the full bodies; no placeholders. Mirror the `string.split`/`float.parse`/`int.parse` idioms already in `shared/wire.gleam` and `pagination.gleam`.)
- [ ] **Step 4: Run** — `cd shared && gleam test` → PASS.
- [ ] **Step 5: Commit**

```bash
git add shared/src/shared/table/query.gleam shared/test/table_test.gleam
git commit -m "Add applied filter/sort/page query-param codec (shared/table/query)"
```

---

## Task 7: Invoice table SQL — null-guard filters, CASE sort, offset page

**Files:**
- Create: `server/src/tempo/server/invoice/sql/invoice_table.sql`
- Regenerate: `server/src/tempo/server/invoice/sql.gleam` (via `bin/squirrel`)

**Interfaces:**
- Produces (after `bin/squirrel`): `sql.invoice_table(db, as_of, status_filter, client_filter, project_filter, engineer_filter, billing_from_lo, billing_from_hi, total_lo, total_hi, sort_key, sort_dir, limit, offset)` returning rows `id, project, client, billing_from, billing_to, status, total, engineers (text[]), issued_at?, paid_at?`.

Approach (each filter is a null-guard so one static query serves every combination; multi-selects use Postgres array params; sort is a `CASE` over `(sort_key, sort_dir)`; pagination is `LIMIT/OFFSET`):

- [ ] **Step 1:** Ensure DB is up and migrated. Run: `bin/db && bin/migrate`. Expected: migrations apply cleanly.

- [ ] **Step 2: Write `invoice_table.sql`** — start from `invoice_list.sql` (Task context shows it). Wrap the existing inner SELECT (add `array_agg` of engineer names from the snapshot lines) in an outer `page` query that applies the null-guards, the CASE sort, and limit/offset:

```sql
-- invoice_table.sql — the generic invoices table read (data-table system). The
-- inner select is invoice_list.sql's row plus an engineers array (the snapshot
-- lines' engineer names). The outer query applies the advertised filters with the
-- (param IS NULL OR match) idiom, a CASE-driven ORDER BY for the active sort, and
-- LIMIT/OFFSET paging. Every filter param is nullable: NULL means "not filtering".
-- $1 as-of; $2 status[]; $3 client[]; $4 project[]; $5 engineer[]; $6 billing_from
-- low; $7 billing_from high; $8 total low; $9 total high; $10 sort key; $11 sort
-- dir ('asc'|'desc'); $12 limit; $13 offset.
SELECT * FROM (
  SELECT
    invoice.id,
    coalesce((SELECT project.title FROM project_current project
              WHERE project.id = invoice_subject.project_id LIMIT 1), '') AS project,
    coalesce((SELECT client.name FROM project_run
              JOIN contract_terms ON contract_terms.contract_id = project_run.contract_id
              JOIN client_current client ON client.id = contract_terms.client_id
              WHERE project_run.project_id = invoice_subject.project_id LIMIT 1), '') AS client,
    lower(invoice_subject.billing_period) AS billing_from,
    upper(invoice_subject.billing_period) AS billing_to,
    invoice_status.status,
    coalesce((SELECT sum(invoice_line.amount) FROM invoice_line
              WHERE invoice_line.invoice_id = invoice.id), 0)::text AS total,
    coalesce((SELECT array_agg(DISTINCT invoice_line.engineer)
              FROM invoice_line WHERE invoice_line.invoice_id = invoice.id), '{}') AS engineers,
    (SELECT lower(issued.status_during) FROM invoice_status issued
      WHERE issued.invoice_id = invoice.id AND issued.status = 'issued'
        AND lower(issued.status_during) <= $1::date LIMIT 1) AS "issued_at?",
    (SELECT lower(paid.status_during) FROM invoice_status paid
      WHERE paid.invoice_id = invoice.id AND paid.status = 'paid'
        AND lower(paid.status_during) <= $1::date LIMIT 1) AS "paid_at?"
  FROM invoice
  JOIN invoice_subject ON invoice_subject.invoice_id = invoice.id
  JOIN invoice_status ON invoice_status.invoice_id = invoice.id
                     AND invoice_status.status_during @> $1::date
) page
WHERE ($2::text[] IS NULL OR page.status = ANY($2::text[]))
  AND ($3::text[] IS NULL OR page.client = ANY($3::text[]))
  AND ($4::text[] IS NULL OR page.project = ANY($4::text[]))
  AND ($5::text[] IS NULL OR page.engineers && $5::text[])
  AND ($6::date  IS NULL OR page.billing_from >= $6::date)
  AND ($7::date  IS NULL OR page.billing_from <= $7::date)
  AND ($8::numeric IS NULL OR page.total::numeric >= $8::numeric)
  AND ($9::numeric IS NULL OR page.total::numeric <= $9::numeric)
ORDER BY
  CASE WHEN $10 = 'total'    AND $11 = 'asc'  THEN page.total::numeric END ASC,
  CASE WHEN $10 = 'total'    AND $11 = 'desc' THEN page.total::numeric END DESC,
  CASE WHEN $10 = 'client'   AND $11 = 'asc'  THEN page.client END ASC,
  CASE WHEN $10 = 'client'   AND $11 = 'desc' THEN page.client END DESC,
  CASE WHEN $10 = 'project'  AND $11 = 'asc'  THEN page.project END ASC,
  CASE WHEN $10 = 'project'  AND $11 = 'desc' THEN page.project END DESC,
  CASE WHEN $10 = 'status'   AND $11 = 'asc'  THEN page.status END ASC,
  CASE WHEN $10 = 'status'   AND $11 = 'desc' THEN page.status END DESC,
  CASE WHEN $10 = 'id'       AND $11 = 'asc'  THEN page.id END ASC,
  CASE WHEN $10 = 'id'       AND $11 = 'desc' THEN page.id END DESC,
  CASE WHEN $11 = 'asc'  THEN page.billing_from END ASC,
  CASE WHEN $11 = 'desc' THEN page.billing_from END DESC,
  page.id
LIMIT $12::int OFFSET $13::int;
```

- [ ] **Step 3: Regenerate typed Gleam.** Run: `bin/squirrel`. Expected: `server/src/tempo/server/invoice/sql.gleam` updates with an `invoice_table` function and an `InvoiceTableRow` type whose `engineers` field is `List(String)`. If Squirrel cannot infer the array, cast explicitly (`array_agg(...)::text[]`) and re-run.

- [ ] **Step 4: Verify it compiles.** Run: `cd server && gleam build`. Expected: builds (the new generated function exists; nothing calls it yet).

- [ ] **Step 5: Commit**

```bash
git add server/src/tempo/server/invoice/sql/invoice_table.sql server/src/tempo/server/invoice/sql.gleam
git commit -m "Add invoice_table SQL: null-guard filters, CASE sort, offset paging"
```

---

## Task 8: Server read module — schema, params, rows→cells

**Files:**
- Create: `server/src/tempo/server/invoice/table.gleam`
- Test: `server/test/table_test.gleam`

**Interfaces:**
- Consumes: `sql.invoice_table`, `shared/table/*`, `context`, `shared/table/query`.
- Produces: `invoice_schema() -> column.Schema` (the static schema), `invoice_table(ctx, as_of, applied) -> Result(response.TableResponse, pog.QueryError)`. `applied: query.Applied` is parsed from the request by the handler. The function maps `applied.filters` → the SQL's nullable params, runs `sql.invoice_table` with `limit = page_size + 0` and `offset = cursor-decoded offset`, maps each row → `response.Row` cells (`#` NumberCell, project EntityCell with a per-id swatch color, client TextCell, team ChipsCell, billing_month DateCell, total MoneyCell, status EnumCell with tone), and builds the `Page` (`next_cursor = Some(encode offset+page_size)` when a full page returned, else `None`).

- [ ] **Step 1: Write the failing test** in `server/test/table_test.gleam` using the `rolling_back` fixture (copy from `financials_test.gleam`): insert 3 invoices across two clients/months/totals, then assert (a) no filter returns all 3 in default sort, (b) a status filter returns only matching rows, (c) sort=total:desc orders by total, (d) page_size=2 returns 2 rows + a non-None cursor. Assert on decoded `response.TableResponse` row cells (`dict.get(row.cells, "total")` etc.), not SQL internals.

- [ ] **Step 2: Run to verify failure** — `cd server && gleam test` → module/function missing.

- [ ] **Step 3: Implement `table.gleam`** — `invoice_schema()` returns the 7-column schema (matches the prototype). Map `query.FilterValue`s to nullable SQL params via small helpers (`select_param(filters, "status")` → `Option(List(String))`, etc.). Color for the project swatch: reuse the client's category convention by sending a `--cat-N` token string keyed off `id` (e.g. `"var(--cat-" <> int 1..7 <> ")"`), matching `ui.swatch`. Status tone: `draft`→Neutral, `issued`→Warning, `paid`→Positive. Initials: first letters of the engineer's name words, uppercased. Write every helper fully.

- [ ] **Step 4: Run** — `cd server && gleam test` → PASS.

- [ ] **Step 5: Commit**

```bash
git add server/src/tempo/server/invoice/table.gleam server/test/table_test.gleam
git commit -m "Add invoice table read: schema, filter/sort params, rows to cells"
```

---

## Task 9: HTTP handler + route + request param helpers

**Files:**
- Modify: `server/src/tempo/server/invoice/http.gleam` (add `handle_table`)
- Modify: `server/src/tempo/server/web/router.gleam` (route `["api","invoices","table"]`)
- Modify: `server/src/tempo/server/web/request.gleam` (param helpers)
- Test: `server/test/api_test.gleam` (route-through assertion)

**Interfaces:**
- Produces: `GET /api/invoices/table?as_of=&filter.*=&sort=&page_size=&cursor=` → `TableResponse` JSON, guarded by `read.finances`.

- [ ] **Step 1: Write the failing test** in `api_test.gleam` (mirror the existing invoice list test): route a request as the Admin principal through `router.route_request`, decode with `response.response_decoder()`, assert the schema's `table_id == "invoices"` and that rows decode. (The base seed has 0 invoices, so assert on the schema + empty rows; the row-content behaviour is covered in Task 8 and e2e.)

- [ ] **Step 2: Run to verify failure.**

- [ ] **Step 3: Implement.** In `request.gleam` add `string_from_query(req, name) -> Option(String)` reuse, and a `query_pairs(req) -> List(#(String,String))` accessor (wraps `wisp.get_query`). In `http.gleam` add `handle_table`: require GET, parse `as_of` (existing helper), build `query.Applied` from the query pairs + `invoice_table.invoice_schema()` (via `query.parse_*`), clamp `page_size` with `context.clamp_limit`, call `invoice_table.invoice_table`, encode `response.encode_response`. Malformed `as_of`/`sort`/`page_size` → 400. In `router.gleam` add the `["api","invoices","table"]` arm guarded by `access.read_finances` BEFORE the `["api","invoices", id]` arm (so `table` is not parsed as an id).

- [ ] **Step 4: Run** — `cd server && gleam test` → PASS.

- [ ] **Step 5: Commit**

```bash
git add server/src/tempo/server/invoice/http.gleam server/src/tempo/server/web/router.gleam server/src/tempo/server/web/request.gleam server/test/api_test.gleam
git commit -m "Serve GET /api/invoices/table (schema + filtered/sorted page)"
```

---

## Task 10: Client `storage` FFI (localStorage)

**Files:**
- Create: `client/src/client/storage.gleam`, `client/src/client/storage_ffi.mjs`

**Interfaces:**
- Produces: `get(key: String) -> Option(String)` (synchronous read for `init`), `set(key: String, value: String) -> Effect(msg)` (fire-and-forget write).

- [ ] **Step 1:** Write `storage_ffi.mjs` with `read(key)` returning the string or `undefined`, and `write(key, value)` wrapped in try/catch (private-mode safety). Mirror `scheduler_ffi.mjs` structure.
- [ ] **Step 2:** Write `storage.gleam`: `get` calls the FFI and maps `undefined`→`None` via a nullable decode boundary; `set` returns `effect.from(fn(_) { write(key, value) })`. Read `scheduler.gleam` for the effect idiom first.
- [ ] **Step 3:** Run `cd client && gleam build`. Expected: compiles.
- [ ] **Step 4: Commit**

```bash
git add client/src/client/storage.gleam client/src/client/storage_ffi.mjs
git commit -m "Add client localStorage FFI (storage.get/set)"
```

---

## Task 11: Client `table` module — state, update, outcome, debounce

**Files:**
- Create: `client/src/client/table.gleam`

**Interfaces:**
- Produces: `State`, `Msg`, `Outcome(Idle | Requery(List(#(String,String))) | PersistLayout(String))`, `init(schema) -> State`, `update(State, Msg) -> #(State, Outcome)`, `view(schema, rows, state) -> Element(Msg)`, plus `apply_response(State, schema) -> State` to reconcile saved layout with the server schema (drop removed columns, append new). The page owns the `State`; on `Requery` it issues `api.get` with the params; on `PersistLayout` it runs `storage.set`.

Detail: `State` holds `order: List(String)`, `hidden: Set(String)`, `applied: query.Applied`, `open_filter: Option(String)`, `filter_token: Int`. Free-text/number-range edits bump `filter_token` and the page schedules `scheduler.after(340, FilterSettled(token))`; `update` emits `Requery` only for a `FilterSettled` whose token matches (mirror the time-rail settle pattern). Discrete changes (checkbox, date, sort, page) emit `Requery` immediately. Column reorder/hide update `order`/`hidden` and emit `PersistLayout(json)`.

- [ ] **Step 1-4:** Build `State`/`Msg`/`init`/`update` with the outcome contract; reconcile layout in `apply_response`. (Pure MVU, no DB — unit-testable. Add focused tests in a new `client/test/table_test.gleam` if a `client/test` harness exists; otherwise rely on the e2e in Task 14.) Run `cd client && gleam build` green.
- [ ] **Step 5: Commit**

```bash
git add client/src/client/table.gleam
git commit -m "Add generic client table MVU (state, update, outcome, debounce)"
```

---

## Task 12: Client `table` view — renderers, filter widgets, columns manager

**Files:**
- Modify: `client/src/client/table.gleam` (the `view` and its registries)

**Interfaces:**
- `render_cell(Cell) -> Element(Msg)` exhaustive on `Cell`; `tone_class(Tone) -> String` exhaustive on `Tone`; `filter_widget(FilterKind, ...) -> Element(Msg)` exhaustive on `FilterKind`. The rail (fixed height, one button per filterable column, popover anchored beneath), sortable headers cycling asc→desc→none, the footer (showing N, page-size select, Load more), and the ⚙ Columns popover (drag-reorder + checkbox hide; pinned columns disabled). Reuse existing CSS atoms (`.cell-name`, `.swatch`, `.avatar`, `.pill--<tone>`, `.chip`, `td.num`) and add the new rail/popover/columns classes in Task 13.

- [ ] **Step 1-4:** Implement the view + the three exhaustive registries. Filters apply immediately (per the approved UX): discrete inputs dispatch a change `Msg` that updates `State` and yields `Requery`; text/number inputs dispatch a debounced settle. Build green: `cd client && gleam build`.
- [ ] **Step 5: Commit**

```bash
git add client/src/client/table.gleam
git commit -m "Add table view: cell renderers, filter widgets, columns manager"
```

---

## Task 13: Table stylesheet

**Files:**
- Create: `client/styles/table.scss`
- Modify: `client/styles/main.scss` (`@use 'table'`)

- [ ] **Step 1:** Author `table.scss` for the rail (`min-height` fixed, `overflow-x:auto`), filter buttons (active/badge/clear), the popover (absolute, shadow), the columns manager rows (drag handle, checkbox, pinned label), and the footer. Use only tokens / `_mixins.scss` mixins (`mono-xs`, `hairline`); no literal hex/size, no `--` decls. Port the visual decisions from the approved artifact.
- [ ] **Step 2:** Add `@use 'table';` to `main.scss` (follow the existing `@use` ordering).
- [ ] **Step 3:** Run `bin/build` then `bin/lint-css`. Expected: bundle builds, token lint passes.
- [ ] **Step 4: Commit**

```bash
git add client/styles/table.scss client/styles/main.scss
git commit -m "Add data-table stylesheet (rail, popover, columns manager)"
```

---

## Task 14: Migrate the Invoices list onto the generic table

**Files:**
- Modify: `client/src/client/page/finance/invoices.gleam`

**Interfaces:**
- Consumes: `client/table`, `client/storage`, `client/scheduler`, `shared/table/response`, `shared/table/query`.

- [ ] **Step 1:** Replace the list fetch with `GET /api/invoices/table` + `response.response_decoder()`; hold a `table.State` and the loaded `TableResponse` in the tab `Model`. Keep detail/op flows as-is. Wire `table.Msg` through the tab `update`, acting on `Outcome` (`Requery`→`api.get` with the params; `PersistLayout`→`storage.set`; row-open click → existing `Navigate`). The detail lines table can stay on `ui.data_table` for now (out of scope).
- [ ] **Step 2:** On `init`, seed `table.State` from `table.init(schema)` after the first response (or from a minimal bootstrap schema, then `apply_response`). Load saved layout via `storage.get`.
- [ ] **Step 3:** Build the client: `bin/build`. Manually sanity-check (optional) by serving. Run `cd client && gleam build` + `gleam format --check src`.
- [ ] **Step 4: Commit**

```bash
git add client/src/client/page/finance/invoices.gleam
git commit -m "Render the invoices list via the generic data table"
```

---

## Task 15: e2e — filter / sort / load-more / column-hide

**Files:**
- Create: `e2e/finance-table.spec.js`

**Interfaces:**
- Consumes: `e2e/helpers.js` (sign-in helpers). The dev DB must hold invoices — `bin/seed-invoices` populates the Jan–Jun pipeline; the spec's `webServer`/global setup runs against a seeded DB.

- [ ] **Step 1:** Read `e2e/financials.spec.js` and `e2e/helpers.js` for the sign-in-as-Admin + navigation patterns and the seeding/`webServer` setup.
- [ ] **Step 2:** Write behaviour-driven tests (assert visible row content changes, never CSS/ids):
  - Applying the **Status = Paid** filter leaves only rows whose status reads "Paid" (count drops; a known draft invoice's row disappears).
  - Sorting by **Total** descending puts the largest amount first (assert the first row's total ≥ the last visible row's).
  - **Load more** increases the number of visible invoice rows.
  - Hiding the **Client** column via the Columns popover removes the Client header; after `page.reload()` it stays hidden (localStorage persistence).
- [ ] **Step 3:** Run: `cd e2e && npx playwright test finance-table.spec.js`. Expected: PASS. (Ensure the server is built with the new client bundle: `bin/build` first; the Playwright `webServer` starts the server.)
- [ ] **Step 4: Commit**

```bash
git add e2e/finance-table.spec.js
git commit -m "e2e: invoices table filter, sort, load-more, column-hide persistence"
```

---

## Task 16: Full green + docs fold-in

- [ ] **Step 1:** Reseed clean for the gleam suite: `docker compose down -v && bin/db && bin/migrate`. Run `bin/test`. Expected: gleam suite + format + css lint all green.
- [ ] **Step 2:** `bin/build && bin/seed-invoices`, then `cd e2e && npx playwright test`. Expected: full e2e green.
- [ ] **Step 3:** Fold the design into `docs/ARCHITECTURE.md` (a "Data table system" section) and add an ADR to `docs/DECISIONS.md` (schema-embedded, typed-columns/exhaustive-unions, null-guard SQL, offset-cursor-now/keyset-later). Move `docs/2026-06-27-data-table-system-design.md` to `docs/archive/`.
- [ ] **Step 4: Commit**

```bash
git add docs/ARCHITECTURE.md docs/DECISIONS.md
git commit -m "Document the data-table system (architecture + ADR)"
git add -- docs/archive/2026-06-27-data-table-system-design.md docs/2026-06-27-data-table-system-design.md
git commit -m "Archive the data-table design doc"
```

---

## Self-Review notes

- **Spec coverage:** filtering (Tasks 6-9, 11-12, 15), sorting (7-9, 12, 15), pagination (7-9, 12, 15), column reorder/hide + localStorage (10-12, 14-15), rich cells by type (4, 8, 12), exhaustive unions (1, 4, 12), immediate-apply + debounce (11-12), Invoices proof (7-9, 14-15). Covered.
- **Deviation from spec (flag to user):** pagination is implemented as an **opaque cursor encoding an offset**, not true keyset. The wire/client are unchanged, so keyset can replace the server internals later with no contract change. Chosen because keyset across arbitrary, heterogeneously-typed user-chosen sort columns is disproportionately complex for this first cut.
- **Risk:** Squirrel array inference for `engineers text[]` and the `CASE` ORDER BY type unification (numeric vs text branches are in separate CASE arms, so each arm is single-typed — required for Postgres). Verify at Task 7 codegen.
