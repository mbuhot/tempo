//// Domain: the engineer-detail READ model (`GET /api/engineers/:id?as_of=`).
//// Assembles one engineer's full profile from several component reads: name +
//// contact from the `engineer_current` view, banking and emergency from their
//// current-version queries, the as-of `Employment` (employment × role × salary),
//// the role/allocation/leave timelines, and the leave `balance` (annual + sick,
//// two `leave_balance` calls assembled into one `LeaveBalance` carrying the
//// engineer's name). The timesheet is a SEPARATE fetch, not inlined here.
////
//// Returns `Result(Result(EngineerDetail, Nil), pog.QueryError)`: `Ok(Error(Nil))`
//// when the engineer has no current contact (no such engineer) so the handler can
//// answer a 404 rather than a 500; `Error(_)` is a database failure. No HTTP —
//// this layer never imports `wisp`.
////
//// Contact is read from the `engineer_current` view (which already exposes
//// name/email/phone/postal_address) via `engineer_contact_current.sql`. The
//// view's columns are nullable to Squirrel, so `contact_to_shared` asserts them
//// present for a row that exists.

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/time/calendar.{type Date}
import pog
import shared/allocation/view.{type AllocationRow, AllocationRow} as _
import shared/engineer/view.{
  type Employment, type EngineerBanking, type EngineerContact,
  type EngineerDetail, type EngineerEmergency, type RoleVersion, Employment,
  EngineerBanking, EngineerContact, EngineerDetail, EngineerEmergency,
  RoleVersion,
} as _
import shared/leave/view.{
  type LeaveBalance, type LeaveRecord, LeaveBalance, LeaveRecord,
} as _
import shared/money.{type Money}
import tempo/server/async.{type AsyncQuery}
import tempo/server/context.{type Context, query_timeout}
import tempo/server/engineer/sql as engineer_sql
import tempo/server/leave/sql as leave_sql

/// Parse a money amount from a trusted SQL `numeric::text` column.
fn money(text: String) -> Money {
  let assert Ok(amount) = money.from_string(text)
  amount
}

/// One engineer's detail as-of `as_of`. `Ok(Error(Nil))` when no current contact
/// (unknown engineer) → the handler answers 404; `Ok(Ok(detail))` otherwise.
///
/// All nine component queries are independent, so they fan out CONCURRENTLY and are
/// awaited together — the wall-clock cost is the slowest one, not their sum. The
/// contact query is the 404 gate: for an unknown engineer the other eight queries
/// still run (returning empty), a few wasted reads on the rare miss in exchange for
/// a single round-trip on the common hit.
pub fn detail(
  context: Context,
  engineer_id: Int,
  as_of: Date,
) -> Result(Result(EngineerDetail, Nil), pog.QueryError) {
  let contact: AsyncQuery(engineer_sql.EngineerContactCurrentRow) =
    async.start(fn() {
      engineer_sql.engineer_contact_current(context.db, engineer_id)
    })
  let banking: AsyncQuery(engineer_sql.EngineerBankingCurrentRow) =
    async.start(fn() {
      engineer_sql.engineer_banking_current(context.db, engineer_id)
    })
  let emergency: AsyncQuery(engineer_sql.EngineerEmergencyCurrentRow) =
    async.start(fn() {
      engineer_sql.engineer_emergency_current(context.db, engineer_id)
    })
  let employment: AsyncQuery(engineer_sql.EngineerEmploymentAsofRow) =
    async.start(fn() {
      engineer_sql.engineer_employment_asof(context.db, engineer_id, as_of)
    })
  let roles: AsyncQuery(engineer_sql.EngineerRoleHistoryRow) =
    async.start(fn() {
      engineer_sql.engineer_role_history(context.db, engineer_id)
    })
  let allocations: AsyncQuery(engineer_sql.EngineerAllocationsRow) =
    async.start(fn() {
      engineer_sql.engineer_allocations(context.db, engineer_id, as_of)
    })
  let leave_history: AsyncQuery(leave_sql.LeaveHistoryRow) =
    async.start(fn() { leave_sql.leave_history(context.db, engineer_id) })
  let annual: AsyncQuery(leave_sql.LeaveBalanceRow) =
    async.start(fn() {
      leave_sql.leave_balance(context.db, engineer_id, "annual", as_of)
    })
  let sick: AsyncQuery(leave_sql.LeaveBalanceRow) =
    async.start(fn() {
      leave_sql.leave_balance(context.db, engineer_id, "sick", as_of)
    })

  let contact = async.await(contact, query_timeout)
  let banking = async.await(banking, query_timeout)
  let emergency = async.await(emergency, query_timeout)
  let employment = async.await(employment, query_timeout)
  let roles = async.await(roles, query_timeout)
  let allocations = async.await(allocations, query_timeout)
  let leave_history = async.await(leave_history, query_timeout)
  let annual = async.await(annual, query_timeout)
  let sick = async.await(sick, query_timeout)

  use contact <- result.try(contact)
  use banking <- result.try(banking)
  use emergency <- result.try(emergency)
  use employment <- result.try(employment)
  use roles <- result.try(roles)
  use allocations <- result.try(allocations)
  use leave_history <- result.try(leave_history)
  use annual <- result.try(annual)
  use sick <- result.map(sick)

  case contact.rows {
    [] -> Error(Nil)
    [contact_row, ..] -> {
      let contact = contact_to_shared(contact_row)
      case banking.rows, emergency.rows, employment.rows {
        [banking, ..], [emergency, ..], [employment, ..] ->
          Ok(EngineerDetail(
            engineer_id:,
            name: contact.name,
            level: employment.level,
            contact:,
            banking: banking_to_shared(banking),
            emergency: emergency_to_shared(emergency),
            employment: employment_to_shared(employment),
            roles: list.map(roles.rows, role_to_shared),
            allocations: list.map(allocations.rows, allocation_to_shared),
            balance: balance(contact.name, annual.rows, sick.rows),
            leave_history: list.map(leave_history.rows, leave_record_to_shared),
          ))
        _, _, _ -> Error(Nil)
      }
    }
  }
}

/// Map an `engineer_contact_current` row to the shared `EngineerContact`. The row
/// comes from the `engineer_current` view, so Squirrel types every column nullable;
/// a row only exists for a known engineer (whose columns are all present), so the
/// mapper asserts each is `Some`.
fn contact_to_shared(
  row: engineer_sql.EngineerContactCurrentRow,
) -> EngineerContact {
  let assert engineer_sql.EngineerContactCurrentRow(
    engineer_id: Some(engineer_id),
    name: Some(name),
    email: Some(email),
    phone: Some(phone),
    postal_address: Some(postal_address),
  ) = row
  EngineerContact(engineer_id:, name:, email:, phone:, postal_address:)
}

fn banking_to_shared(
  row: engineer_sql.EngineerBankingCurrentRow,
) -> EngineerBanking {
  EngineerBanking(
    engineer_id: row.engineer_id,
    bank: row.bank,
    branch: row.branch,
    account_no: row.account_no,
    account_name: row.account_name,
  )
}

fn emergency_to_shared(
  row: engineer_sql.EngineerEmergencyCurrentRow,
) -> EngineerEmergency {
  EngineerEmergency(
    engineer_id: row.engineer_id,
    relation: row.relation,
    name: row.name,
    phone: row.phone,
    email: row.email,
  )
}

fn employment_to_shared(
  row: engineer_sql.EngineerEmploymentAsofRow,
) -> Employment {
  Employment(
    engineer_id: row.engineer_id,
    started: row.started,
    level: row.level,
    monthly_salary: money(row.monthly_salary),
  )
}

fn role_to_shared(row: engineer_sql.EngineerRoleHistoryRow) -> RoleVersion {
  RoleVersion(
    level: row.level,
    valid_from: row.valid_from,
    valid_to: open_end(row.ongoing, row.valid_to),
  )
}

/// An open (`ongoing`) period has no end date; otherwise its coalesced upper bound.
fn open_end(ongoing: Bool, valid_to: Date) -> Option(Date) {
  case ongoing {
    True -> None
    False -> Some(valid_to)
  }
}

fn allocation_to_shared(
  row: engineer_sql.EngineerAllocationsRow,
) -> AllocationRow {
  AllocationRow(
    project_id: row.project_id,
    project: row.project,
    fraction: row.fraction,
    valid_from: row.valid_from,
    valid_to: open_end(row.ongoing, row.valid_to),
    active: row.active,
  )
}

fn leave_record_to_shared(row: leave_sql.LeaveHistoryRow) -> LeaveRecord {
  LeaveRecord(
    kind: row.kind,
    valid_from: row.valid_from,
    valid_to: row.valid_to,
  )
}

/// Assemble the engineer's leave balance from the two `leave_balance` calls (annual
/// and sick), carrying the engineer's `name`. A missing balance row reads 0.0.
fn balance(
  name: String,
  annual_rows: List(leave_sql.LeaveBalanceRow),
  sick_rows: List(leave_sql.LeaveBalanceRow),
) -> LeaveBalance {
  LeaveBalance(
    engineer: name,
    annual: balance_value(annual_rows),
    sick: balance_value(sick_rows),
  )
}

fn balance_value(rows: List(leave_sql.LeaveBalanceRow)) -> Float {
  case rows {
    [row, ..] -> row.balance
    [] -> 0.0
  }
}
