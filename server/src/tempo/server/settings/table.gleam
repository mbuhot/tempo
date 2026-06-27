//// Domain: the settings generic-table reads (data-table system) — the rate card &
//// salary bands and the leave policy as-of a date. Builds the table `Schema` the
//// client renders from and maps each row to typed `Cell`s.
////
//// Both tables are tiny — one row per level — so there is no filtering, sorting,
//// or paging: every column is `sortable: False`, `filter: None`, and the page
//// carries no `next_cursor`. The rate-card table carries an `ActionsType` column
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
import shared/money.{type Money}
import shared/settings/view.{
  type LeavePolicyRow, type RateCardRow, type SalaryRow,
}
import shared/table/cell.{
  type Cell, Action, ActionsCell, EnumCell, MoneyCell, NumberCell, TextCell,
}
import shared/table/column.{
  type Schema, ActionsType, Column, EnumType, MoneyType, Neutral, NumberType,
  NumericEnd, Schema, Start, TextType,
}
import shared/table/response.{
  type Row, type TableResponse, Page, Row, TableResponse,
}
import tempo/server/auth
import tempo/server/context.{type Context}
import tempo/server/settings/view as settings

/// The rate-card & salary-bands table as-of `as_of`: one row per level present in
/// the rate card (level band, day rate, monthly salary, and the per-row actions the
/// principal may perform), plus the schema the client renders from.
pub fn rate_card_table(
  context: Context,
  as_of: Date,
) -> Result(TableResponse, pog.QueryError) {
  use settings <- result.map(settings.read(context, as_of))
  let actions = available_actions(context)
  TableResponse(
    schema: rate_card_schema(),
    rows: list.map(settings.rate_card, fn(rate) {
      rate_card_row(rate, settings.salaries, actions)
    }),
    page: Page(next_cursor: None),
  )
}

/// The leave-policy table as-of `as_of`: one read-only row per policy line (leave
/// kind, level band, days-per-year), plus the schema. No actions — leave policy is
/// presented as facts only.
pub fn leave_policy_table(
  context: Context,
  as_of: Date,
) -> Result(TableResponse, pog.QueryError) {
  use settings <- result.map(settings.read(context, as_of))
  TableResponse(
    schema: leave_policy_schema(),
    rows: list.map(settings.leave_policy, leave_policy_row),
    page: Page(next_cursor: None),
  )
}

// --- schema -----------------------------------------------------------------

/// The rate-card & salary table schema: level, day rate, monthly salary, and a
/// non-sortable, non-filterable actions column.
pub fn rate_card_schema() -> Schema {
  Schema(
    table_id: "settings_rate_card",
    default_sort: None,
    filters: [],
    columns: [
      Column(
        key: "level",
        label: "Level",
        column_type: EnumType,
        align: Start,
        sortable: False,
        hideable: False,
        filter: None,
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
        label: "",
        column_type: ActionsType,
        align: NumericEnd,
        sortable: False,
        hideable: False,
        filter: None,
      ),
    ],
  )
}

/// The read-only leave-policy table schema: leave kind, level band, days-per-year.
pub fn leave_policy_schema() -> Schema {
  Schema(
    table_id: "settings_leave_policy",
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
        filter: None,
      ),
      Column(
        key: "level",
        label: "Level",
        column_type: EnumType,
        align: Start,
        sortable: False,
        hideable: False,
        filter: None,
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
      #("level", EnumCell(label: level_band(rate.level), tone: Neutral)),
      #("day_rate", MoneyCell(rate.day_rate)),
      #("monthly_salary", salary_cell(salaries, rate.level)),
      #("actions", ActionsCell(actions)),
    ]),
    children: [],
  )
}

fn leave_policy_row(policy: LeavePolicyRow) -> Row {
  Row(
    id: policy.kind <> ":" <> int.to_string(policy.level),
    cells: dict.from_list([
      #("kind", TextCell(policy.kind)),
      #("level", EnumCell(label: level_band(policy.level), tone: Neutral)),
      #("days_per_year", NumberCell(policy.days_per_year)),
    ]),
    children: [],
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

/// The level's band label (mirrors the client's `ui.level_band`).
fn level_band(level: Int) -> String {
  let band = case level {
    1 -> "Associate"
    2 -> "Engineer"
    3 -> "Senior"
    4 -> "Staff"
    5 -> "Principal"
    6 -> "Distinguished"
    7 -> "Fellow"
    _ -> "Engineer"
  }
  "L" <> int.to_string(level) <> " · " <> band
}
