# Data Table System — Design

**Date:** 2026-06-27
**Status:** Proposed
**UI prototype:** https://claude.ai/code/artifact/1a9fe77f-35b3-46ba-8899-cab834dff49f

## Summary

One generic, data-driven table that backs every list in the app. The server returns
a **schema** alongside the data on each list request; the client interprets that
schema to render rich cells and offer the right filter for each column. The table
component knows nothing about invoices, people, or projects — it knows how to render
a fixed catalogue of column **data-types** and how to present a fixed catalogue of
**filter kinds**.

| Capability | Owner | Persistence |
|---|---|---|
| Filtering | Server advertises options; server applies | URL query params |
| Sorting | Server advertises sortable columns; server applies | URL query params |
| Pagination | Universal keyset (cursor) convention | URL query param |
| Column re-ordering | Client only | `localStorage`, per user, per table |
| Column hiding | Client only | `localStorage`, per user, per table |

The build-time safety net: column data-types and cell payloads are **Gleam unions in
`shared/`**, switched on with exhaustive `case` (no `_` arm). Adding a new column type
fails the build at every site that must learn to handle it.

## Goals

- A single table component reused by all list pages; no per-table layout code.
- The server decides what can be filtered and sorted, and supplies filter options
  (including data-driven options such as the live client list).
- Rich, type-specific cell rendering (money, dates, status pills, project swatches,
  team avatars) driven by the column's declared data-type.
- A compact filter UI: a fixed-height rail, one control per filterable column, each
  expanding to a popover for its detail. No second row, no layout shift.
- Per-user column order and visibility, remembered across reloads.
- Adding a new column data-type is a compile error until every handler is updated.

## Non-goals

- Migrating every list page now. We build the system and migrate **Invoices** as the
  proof; other pages follow one at a time.
- Server-side persistence of column layout (a future enhancement; `localStorage` now).
- Multi-column sort (single active sort key now; the wire shape leaves room to grow).
- Inline editing of cells.

## The core idea: type the columns, decode into typed cells

Two layers, kept in lockstep:

1. **On the wire**, a cell is *bare data* with no per-cell type tag. The column's
   declared `type` is the single source of truth for how to read and render it. A
   `money` column's cell is a number; an `entity` column's cell is `{label, color}`.

2. **In Gleam**, that bare data is decoded — guided by the column type — into a typed
   `Cell` union. Rendering then pattern-matches the `Cell`. Both the type-directed
   decoder and the renderer are exhaustive, so the two unions stay in lockstep and the
   compiler enforces coverage end to end.

```
wire cell (untagged)  --cell_decoder(column.type)-->  Cell (typed union)  --render_cell-->  Element
       ^                         ^ exhaustive case on ColumnType              ^ exhaustive case on Cell
   small payload,            adding a ColumnType                          adding a Cell variant
   no redundant tag          breaks this decoder                         breaks this renderer
```

## Wire contract (`shared/table/`)

A new domain concept `table`, following the per-concept CQRS layout. It owns the
cross-cutting table primitives every list endpoint shares.

```
shared/src/shared/table/
  column.gleam   # ColumnType, Tone, Column, Schema (+ codecs)
  filter.gleam   # FilterKind, FilterOption, applied-filter encode/decode (query params)
  cell.gleam     # Cell, Chip, type-directed cell decoder + encoder
  response.gleam # TableResponse envelope (schema + rows + page), Row
  sort.gleam     # SortSpec, SortDir (+ codecs)
```

### Column types and tones

```gleam
// shared/table/column.gleam
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

pub type Column {
  Column(
    key: String,
    label: String,
    column_type: ColumnType,
    align: Align,
    sortable: Bool,
    hideable: Bool,
    filter: Option(filter.FilterKind),
  )
}

pub type Align {
  Start
  NumericEnd
}

pub type Schema {
  Schema(table_id: String, columns: List(Column), default_sort: Option(sort.SortSpec))
}
```

`table_id` keys the client's `localStorage` layout. `hideable: False` pins a column
(the invoice number); the client always shows it.

The union starts at the catalogue the proof needs. Growth is safe by construction:
adding `DateTimeType`, `LinkType`, etc. is a compile error until handled.

### Cells (approach A: typed cell union)

```gleam
// shared/table/cell.gleam
pub type Cell {
  TextCell(String)
  NumberCell(Float)
  MoneyCell(money.Money)
  DateCell(calendar.Date)
  EnumCell(label: String, tone: column.Tone)
  EntityCell(label: String, color: String)
  PersonCell(name: String, sub: Option(String), initials: String, color: String)
  ChipsCell(List(Chip))
  BoolCell(Bool)
}

pub type Chip { Chip(label: String, initials: Option(String), color: Option(String)) }
```

The type-directed decoder maps a column type to the decoder for its cell payload —
**exhaustive on `ColumnType`** (site #1):

```gleam
pub fn cell_decoder(of column_type: ColumnType) -> Decoder(Cell) {
  case column_type {
    TextType   -> decode.map(decode.string, TextCell)
    NumberType -> decode.map(decode.float, NumberCell)
    MoneyType  -> decode.map(money.decoder(), MoneyCell)
    DateType   -> decode.map(wire.date_decoder(), DateCell)
    EnumType   -> enum_cell_decoder()
    EntityType -> entity_cell_decoder()
    PersonType -> person_cell_decoder()
    ChipsType  -> chips_cell_decoder()
    BoolType   -> decode.map(decode.bool, BoolCell)
    // no `_` — a new ColumnType fails to compile here
  }
}
```

Encoding (server) mirrors it — **exhaustive on `Cell`** (site #2):
`encode_cell(Cell) -> Json`.

### Envelope and rows

```gleam
// shared/table/response.gleam
pub type TableResponse {
  TableResponse(schema: Schema, rows: List(Row), page: Page)
}

pub type Row { Row(id: String, cells: Dict(String, Cell)) }
```

`Page` reuses the existing `shared/pagination` `next_cursor` field. Decoding a
`TableResponse` decodes the schema first, then decodes each row's cells by looking up
each column's type and applying `cell_decoder`.

### Filters

```gleam
// shared/table/filter.gleam
pub type FilterKind {
  TextFilter
  SelectFilter(options: List(FilterOption), multi: Bool)
  NumberRangeFilter
  DateRangeFilter
  BoolFilter
}

pub type FilterOption { FilterOption(value: String, label: String) }
```

`SelectFilter` carries server-supplied options, so data-driven option lists (clients,
projects, engineers) are advertised live. The client's filter-widget picker is
**exhaustive on `FilterKind`** (site #3).

### Query encoding (client → server)

Applied filters, sort, and page are URL query params — shareable and bookmarkable.

| Concern | Param shape | Example |
|---|---|---|
| Select filter | `filter.<key>=v1,v2` | `filter.status=draft,issued` |
| Number range | `filter.<key>.min` / `.max` | `filter.total.min=50000` |
| Date range | `filter.<key>.from` / `.to` | `filter.billing_month.from=2026-02` |
| Text filter | `filter.<key>=substr` | `filter.client=glob` |
| Sort | `sort=<key>:<dir>` | `sort=total:desc` |
| Page size | `page_size=<n>` | `page_size=15` |
| Cursor | `cursor=<opaque>` | `cursor=eyJ2…` |

**Cursor reset rule:** any change to filters or sort drops the cursor and re-queries
from the first page. The cursor is only valid within a fixed filter+sort ordering.

## Server side

Each list endpoint returns a `TableResponse`. A concept handler:

1. Builds its **static `Schema`** (the columns it offers, their types, sortable flags,
   and filter kinds; `SelectFilter` options may be fetched live).
2. Parses the generic query params into a typed filter/sort/page request.
3. Maps that request to **SQL** — concept-specific glue translating each column key to
   its SQL column and supported operators, building a parameterised `WHERE` and
   `ORDER BY`.
4. Runs the query with the `limit + 1` look-ahead and hands rows to `pagination.paginate`.
5. Maps each DB row to `Dict(String, Cell)` and encodes the `TableResponse`.

**Keyset ordering with arbitrary sort columns:** `ORDER BY <sort_col> <dir>, id <dir>`
with the row id as the unique tiebreaker. The cursor encodes `(sort_value, id)` — two
fields — so `pagination.decode_cursor(token, 2)` round-trips. Switching the sort column
changes the ordering and therefore resets the cursor (per the reset rule).

Only columns the schema marks `sortable` / `filter`-able are honoured; an unknown or
unsupported param is a `400`, consistent with the cursor-validation convention.

## Client side

### A reusable table module (`client/table.gleam`)

The table is a self-contained MVU unit the page embeds:

```gleam
pub type State    // order, hidden set, sort, applied filters, page_size
pub type Msg      // header clicked, filter changed, page-size changed, load more,
                  // column toggled, column reordered, popover opened/closed

pub fn init(schema: Schema) -> State          // seeds from default_sort + saved layout
pub fn update(State, Msg) -> #(State, Outcome)
pub fn view(schema: Schema, rows: List(Row), State) -> Element(Msg)

pub type Outcome {
  Idle                     // local-only change already applied (popover open/close)
  Requery(QueryParams)     // filter/sort/page changed → page must refetch
  PersistLayout(Json)      // column order/visibility changed → write localStorage
}
```

The page owns one `table.State` in its model, forwards `table.Msg`, and acts on
`Outcome`: `Requery` issues `api.get` with the encoded params and the generic
`TableResponse` decoder; `PersistLayout` runs the storage effect. Server-bound state
(filters/sort/page) lives in the URL; layout state lives in `localStorage`.

**Filters apply immediately.** A discrete change (checkbox, date) yields `Requery` on
the spot. Free-typing inputs (text, number range) are **debounced with the existing
token-guarded `client/scheduler` pattern** (the same mechanism the as-of rail uses): a
keystroke updates `State` instantly, bumps a `filter_token`, and schedules
`scheduler.after(~340, FilterSettled(token))`; only a `FilterSettled` whose token is
still current emits `Requery`. Superseded keystrokes bump the token to a no-op, so a
burst collapses to one server round-trip. The popover stays open across changes;
clicking outside closes it without any commit step.

### The two registries (exhaustiveness sites)

- **`render_cell(Cell) -> Element(msg)`** — exhaustive on `Cell`. Renders the rich
  markup per the existing CSS atoms (`.cell-name` + `.swatch` for entity, `.avatar`
  chips for chips, `.pill--<tone>` for enum, mono right-aligned for money/number/date).
- **`filter_widget(FilterKind, applied) -> Element(msg)`** — exhaustive on `FilterKind`.
  Renders the popover body: checkbox list with counts, min/max inputs, from/to month
  inputs, or a text input.

A `Tone` → pill-class mapping is a fourth exhaustive `case` (on `Tone`).

### Filter rail UX (from the approved prototype)

- A fixed-height rail under the panel head: a label, one button per filterable column,
  a spacer, then **Reset all**.
- An inactive button shows the column label and a chevron. An active button switches to
  accent styling, shows a count badge, and an inline clear (✕).
- Clicking a button opens a popover anchored beneath it with the type-appropriate
  widget. The rail never changes height; detail lives in the popover.
- **Filters apply immediately**, with no confirm step. Selecting a checkbox or picking
  a date re-queries at once and leaves the popover open for further choices; clicking
  away just closes the popover. Free-typing inputs (text, number range) **debounce**
  (~340 ms) so a query fires once the user pauses, throttling server load. A small
  "filtering… / applied" hint in the popover footer shows the debounce state. Each
  popover has a "Clear filter" link for that column.
- Sorting: clicking a sortable header cycles ascending → descending → none, with an
  indicator in the header.
- Pagination: a footer shows "Showing N of M matching", a page-size selector, and
  **Load more** that requests the next keyset page.

### Column manager and persistence

The **⚙ Columns** popover lists every column with a drag handle and a checkbox. Drag to
reorder; uncheck to hide; pinned columns show their checkbox disabled. "Reset layout"
restores the schema default.

`localStorage` key: `tempo.table.<table_id>.layout` →
`{ "order": [keys], "hidden": [keys] }`. A small `client/storage.gleam` FFI wraps
`localStorage` get/set behind Lustre effects.

**Schema reconciliation:** on load, the saved layout is merged with the server schema —
columns the server no longer sends are dropped from `order`/`hidden`; newly added
columns are appended, visible. This keeps an old saved layout valid across schema
changes.

## Proof page: Invoices

Migrate the Invoices list onto the system. Columns and their behaviour:

| Column | Type | Sortable | Filter |
|---|---|---|---|
| # | number (pinned) | yes | number range |
| Project | entity (swatch + name) | yes | select (multi) |
| Client | text | yes | select (multi) |
| Team | chips (engineer avatars) | no | select (multi, "contains any") |
| Billing month | date | yes | date range (month) |
| Total | money | yes | number range |
| Status | enum (pill) | yes | select (multi) |

Row click opens the existing invoice detail. The bespoke invoice row/table code is
replaced by the generic component plus the server-built schema.

## Testing

- **`shared` unit tests:** round-trip codecs for `Schema`, every `Cell` variant via the
  type-directed decoder/encoder, `TableResponse`, and query-param encode/decode. A test
  that constructs a value of each `ColumnType` guards the exhaustive decoder.
- **Server unit tests:** the Invoices endpoint under each filter, each sort direction,
  and pagination. The base seed carries no invoices, so these tests **insert their own
  invoices in the test fixture/transaction** for deterministic, isolated assertions
  rather than depending on a seed.
- **e2e (Playwright):** signed in as Admin (financial data), assert the *list content
  changes*: applying a status filter removes non-matching rows; sorting by total
  reorders; Load more appends; hiding a column removes it and the choice survives a
  reload (`localStorage`). Behaviour-driven — assert visible rows, not classes.

## Decisions and alternatives

- **Schema embedded in every list response** over a separate describe endpoint — one
  round-trip, schema always consistent with the data, and live filter options stay
  fresh.
- **Approach A: a typed `Cell` union** over an opaque `Cell` holding `Json`. A carries
  the build-time guarantee end to end and matches the codebase's typed read-model style;
  the cost is two parallel unions, each independently exhaustive-checked.
- **Cells untagged on the wire, decoded by column type** keeps payloads small and honours
  "type the columns": the type lives once on the column, not on every cell.
- **`localStorage` for column layout** over server persistence — layout is a per-device
  UI preference; server persistence is deferred.
- **Single-column sort** now; the `SortSpec` shape leaves room for a future list.

## Settled in the prototype

- `Team` filtering is **contains-any** of the selected engineers.
- Page-size options are **8 / 15 / 25**.

## Deferred

- Server-supplied default-hidden columns (sent but collapsed until opt-in). The
  schema/layout reconciliation makes this a small, non-breaking addition when a table
  needs it; the first cut keeps every column visible by default.
