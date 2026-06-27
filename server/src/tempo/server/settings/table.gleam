//// Domain: the settings generic-table reads (data-table system) — the rate card &
//// salary bands and the leave policy as-of a date. Builds the table `Schema` the
//// client renders from and maps each row to typed `Cell`s.
////
//// Both tables are tiny — one row per level — so there is no sorting or paging:
//// every column is `sortable: False` and the page carries no `next_cursor`. The
//// rate card offers a `level` select filter; the leave policy offers `level` and
//// `kind` select filters; both are applied in Gleam over the loaded row lists.
//// The rate-card table carries an `ActionsType` column
//// whose per-row `ActionsCell` advertises the Revise-rate and Set-salary actions
//// the signed-in principal may perform (gated by `ratecard.manage` / `salary.set`),
//// so availability is decided server-side. Each rate-card row's id is its level.

import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/time/calendar.{type Date}
import pog
import shared/access
import shared/level
import shared/money.{type Money}
import shared/settings/view.{
  type LeavePolicyRow, type RateCardRow, type SalaryRow,
}
import shared/table/cell.{
  type Cell, Action, ActionsCell, MoneyCell, NumberCell, TextCell,
}
import shared/table/column.{
  type Schema, ActionsType, Column, EntityType, MoneyType, NumberType,
  NumericEnd, Schema, Start, TextType,
}
import shared/table/filter.{FilterOption, SelectFilter}
import shared/table/query.{type Applied}
import shared/table/response.{
  type Row, type TableResponse, Page, Row, TableResponse,
}
import tempo/server/auth
import tempo/server/context.{type Context}
import tempo/server/settings/view as settings
import tempo/server/table/builder

/// The rate-card & salary-bands table as-of `as_of`: one row per level present in
/// the rate card (level band, day rate, monthly salary, and the per-row actions the
/// principal may perform), plus the schema the client renders from.
pub fn rate_card_table(
  context: Context,
  as_of: Date,
  applied: Applied,
) -> Result(TableResponse, pog.QueryError) {
  use settings <- result.map(settings.read(context, as_of))
  let actions = available_actions(context)
  let levels = builder.select_values(applied.filters, "level")
  let rates =
    list.filter(settings.rate_card, fn(rate) { keep_level(rate.level, levels) })
  TableResponse(
    schema: rate_card_schema(settings.rate_card),
    rows: list.map(rates, fn(rate) {
      rate_card_row(rate, settings.salaries, actions)
    }),
    page: Page(next_cursor: None),
    footer: None,
  )
}

/// The leave-policy table as-of `as_of`: one read-only row per policy line (leave
/// kind, level band, days-per-year), plus the schema. No actions — leave policy is
/// presented as facts only.
pub fn leave_policy_table(
  context: Context,
  as_of: Date,
  applied: Applied,
) -> Result(TableResponse, pog.QueryError) {
  use settings <- result.map(settings.read(context, as_of))
  let levels = builder.select_values(applied.filters, "level")
  let kinds = builder.select_values(applied.filters, "kind")
  let policy =
    list.filter(settings.leave_policy, fn(line) {
      keep_level(line.level, levels) && keep_kind(line.kind, kinds)
    })
  TableResponse(
    schema: leave_policy_schema(settings.leave_policy),
    rows: list.map(policy, leave_policy_row),
    page: Page(next_cursor: None),
    footer: None,
  )
}

/// Keep a row when no `level` filter is set, else only when its level is selected.
fn keep_level(level: Int, selected: option.Option(List(String))) -> Bool {
  case selected {
    None -> True
    Some(values) -> list.contains(values, int.to_string(level))
  }
}

/// Keep a row when no `kind` filter is set, else only when its kind is selected.
fn keep_kind(kind: String, selected: option.Option(List(String))) -> Bool {
  case selected {
    None -> True
    Some(values) -> list.contains(values, kind)
  }
}

// --- schema -----------------------------------------------------------------

/// The rate-card & salary table schema: level (with a `level` select filter built
/// from the present rates), day rate, monthly salary, and a non-sortable,
/// non-filterable actions column.
pub fn rate_card_schema(rate_card: List(RateCardRow)) -> Schema {
  Schema(
    table_id: "settings_rate_card",
    child_columns: None,
    default_sort: None,
    filters: [],
    columns: [
      Column(
        key: "level",
        label: "Level",
        column_type: EntityType,
        align: Start,
        sortable: False,
        hideable: False,
        filter: Some(level_filter(list.map(rate_card, fn(rate) { rate.level }))),
      ),
      Column(
        key: "day_rate",
        label: "Day rate",
        column_type: MoneyType,
        align: NumericEnd,
        sortable: False,
        hideable: False,
        filter: None,
      ),
      Column(
        key: "monthly_salary",
        label: "Monthly salary",
        column_type: MoneyType,
        align: NumericEnd,
        sortable: False,
        hideable: False,
        filter: None,
      ),
      Column(
        key: "actions",
        label: "Actions",
        column_type: ActionsType,
        align: NumericEnd,
        sortable: False,
        hideable: False,
        filter: None,
      ),
    ],
  )
}

/// The read-only leave-policy table schema: leave kind (with a `kind`/"Type" select
/// filter), level band (with a `level` select filter), days-per-year. Both filters'
/// options are built from the present policy lines.
pub fn leave_policy_schema(leave_policy: List(LeavePolicyRow)) -> Schema {
  Schema(
    table_id: "settings_leave_policy",
    child_columns: None,
    default_sort: None,
    filters: [],
    columns: [
      Column(
        key: "kind",
        label: "Type",
        column_type: TextType,
        align: Start,
        sortable: False,
        hideable: False,
        filter: Some(
          kind_filter(list.map(leave_policy, fn(line) { line.kind })),
        ),
      ),
      Column(
        key: "level",
        label: "Level",
        column_type: EntityType,
        align: Start,
        sortable: False,
        hideable: False,
        filter: Some(
          level_filter(list.map(leave_policy, fn(line) { line.level })),
        ),
      ),
      Column(
        key: "days_per_year",
        label: "Days / year",
        column_type: NumberType,
        align: NumericEnd,
        sortable: False,
        hideable: False,
        filter: None,
      ),
    ],
  )
}

/// The rate-card schema with empty filter options — its column filter KINDS are all
/// the web boundary needs to parse the applied filters out of the query params.
pub fn rate_card_filter_schema() -> Schema {
  rate_card_schema([])
}

/// The leave-policy schema with empty filter options — its column filter KINDS are
/// all the web boundary needs to parse the applied filters out of the query params.
pub fn leave_policy_filter_schema() -> Schema {
  leave_policy_schema([])
}

/// A multi-select `level` filter with one option per distinct level present (sorted
/// ascending), each labelled by its band.
fn level_filter(levels: List(Int)) -> filter.FilterKind {
  let options =
    levels
    |> list.unique
    |> list.sort(int.compare)
    |> list.map(fn(level) {
      FilterOption(value: int.to_string(level), label: level.band(level))
    })
  SelectFilter(multi: True, options:)
}

/// A multi-select `kind`/"Type" filter with one option per distinct leave kind
/// present, the kind as both value and label.
fn kind_filter(kinds: List(String)) -> filter.FilterKind {
  let options =
    kinds
    |> list.unique
    |> list.map(fn(kind) { FilterOption(value: kind, label: kind) })
  SelectFilter(multi: True, options:)
}

// --- actions ----------------------------------------------------------------

/// The per-row actions the signed-in principal may perform on a rate-card row,
/// gated by the same permissions the write commands require: `ratecard.manage`
/// advertises Revise, `salary.set` advertises Set-salary. An unauthenticated or
/// under-privileged principal gets an empty action list, so the buttons never show.
fn available_actions(context: Context) -> List(cell.Action) {
  let revise = case can(context, access.ratecard_manage) {
    True -> [Action(id: "revise_rate", label: "Revise")]
    False -> []
  }
  let set_salary = case can(context, access.salary_set) {
    True -> [Action(id: "set_salary", label: "Set salary")]
    False -> []
  }
  list.append(revise, set_salary)
}

fn can(context: Context, permission: String) -> Bool {
  case context.principal {
    Some(principal) -> auth.can(principal, permission)
    None -> False
  }
}

// --- row to cells -----------------------------------------------------------

fn rate_card_row(
  rate: RateCardRow,
  salaries: List(SalaryRow),
  actions: List(cell.Action),
) -> Row {
  Row(
    id: int.to_string(rate.level),
    cells: dict.from_list([
      #("level", level.cell(rate.level)),
      #("day_rate", MoneyCell(rate.day_rate)),
      #("monthly_salary", salary_cell(salaries, rate.level)),
      #("actions", ActionsCell(actions)),
    ]),
    children: [],
    detail: None,
  )
}

fn leave_policy_row(policy: LeavePolicyRow) -> Row {
  Row(
    id: policy.kind <> ":" <> int.to_string(policy.level),
    cells: dict.from_list([
      #("kind", TextCell(policy.kind)),
      #("level", level.cell(policy.level)),
      #("days_per_year", NumberCell(policy.days_per_year)),
    ]),
    children: [],
    detail: None,
  )
}

/// The monthly salary cell for a level: the band's salary as money, or a zero
/// placeholder rendered as "—" by the client when no salary band covers the level.
fn salary_cell(salaries: List(SalaryRow), level: Int) -> Cell {
  case list.find(salaries, fn(salary) { salary.level == level }) {
    Ok(salary) -> MoneyCell(salary.monthly_salary)
    Error(Nil) -> MoneyCell(zero_money())
  }
}

fn zero_money() -> Money {
  let assert Ok(amount) = money.from_string("0")
  amount
}
