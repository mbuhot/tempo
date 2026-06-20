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
//// Contact is read from `engineer_current` (the view already exposes
//// name/email/phone/postal_address) via an inline query rather than a dedicated
//// `.sql` file — there is no Squirrel reader for the view and one is not needed.

import gleam/dynamic/decode
import gleam/list
import gleam/result
import gleam/time/calendar.{type Date}
import pog
import shared/types.{
  type AllocationRow, type Employment, type EngineerBanking,
  type EngineerContact, type EngineerDetail, type EngineerEmergency,
  type LeaveBalance, type LeaveRecord, type RoleVersion, AllocationRow,
  Employment, EngineerBanking, EngineerContact, EngineerDetail,
  EngineerEmergency, LeaveBalance, LeaveRecord, RoleVersion,
}
import tempo/server/context.{type Context}
import tempo/server/sql

/// One engineer's detail as-of `as_of`. `Ok(Error(Nil))` when no current contact
/// (unknown engineer) → the handler answers 404; `Ok(Ok(detail))` otherwise.
pub fn detail(
  context: Context,
  engineer_id: Int,
  as_of: Date,
) -> Result(Result(EngineerDetail, Nil), pog.QueryError) {
  use contact_rows <- result.try(current_contact(context, engineer_id))
  case contact_rows {
    [] -> Ok(Error(Nil))
    [contact, ..] -> assemble(context, engineer_id, as_of, contact)
  }
}

/// Read the remaining component facts and bundle them into an `EngineerDetail`. The
/// contact (and the engineer's `name`/`level`) anchor the bundle; banking/emergency,
/// the as-of employment, the role/allocation/leave timelines, and the annual/sick
/// balance each come from their own query.
fn assemble(
  context: Context,
  engineer_id: Int,
  as_of: Date,
  contact: EngineerContact,
) -> Result(Result(EngineerDetail, Nil), pog.QueryError) {
  use banking <- result.try(sql.engineer_banking_current(
    context.db,
    engineer_id,
  ))
  use emergency <- result.try(sql.engineer_emergency_current(
    context.db,
    engineer_id,
  ))
  use employment <- result.try(sql.engineer_employment_asof(
    context.db,
    engineer_id,
    as_of,
  ))
  use roles <- result.try(sql.engineer_role_history(context.db, engineer_id))
  use allocations <- result.try(sql.engineer_allocations(
    context.db,
    engineer_id,
    as_of,
  ))
  use leave_history <- result.try(sql.leave_history(context.db, engineer_id))
  use annual <- result.try(sql.leave_balance(
    context.db,
    engineer_id,
    "annual",
    as_of,
  ))
  use sick <- result.map(sql.leave_balance(
    context.db,
    engineer_id,
    "sick",
    as_of,
  ))

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

/// Read the engineer's current contact (name/email/phone/postal_address) from the
/// `engineer_current` view directly (no dedicated `.sql` reader exists; the view
/// already exposes these columns). Empty list = unknown engineer → 404.
fn current_contact(
  context: Context,
  engineer_id: Int,
) -> Result(List(EngineerContact), pog.QueryError) {
  let decoder = {
    use id <- decode.field(0, decode.int)
    use name <- decode.field(1, decode.string)
    use email <- decode.field(2, decode.string)
    use phone <- decode.field(3, decode.string)
    use postal_address <- decode.field(4, decode.string)
    decode.success(EngineerContact(
      engineer_id: id,
      name:,
      email:,
      phone:,
      postal_address:,
    ))
  }
  use returned <- result.map(
    engineer_current_sql
    |> pog.query
    |> pog.parameter(pog.int(engineer_id))
    |> pog.returning(decoder)
    |> pog.execute(context.db),
  )
  returned.rows
}

const engineer_current_sql = "SELECT id, name, email, phone, postal_address
FROM engineer_current
WHERE id = $1;"

fn banking_to_shared(row: sql.EngineerBankingCurrentRow) -> EngineerBanking {
  EngineerBanking(
    engineer_id: row.engineer_id,
    bank: row.bank,
    branch: row.branch,
    account_no: row.account_no,
    account_name: row.account_name,
  )
}

fn emergency_to_shared(
  row: sql.EngineerEmergencyCurrentRow,
) -> EngineerEmergency {
  EngineerEmergency(
    engineer_id: row.engineer_id,
    relation: row.relation,
    name: row.name,
    phone: row.phone,
    email: row.email,
  )
}

fn employment_to_shared(row: sql.EngineerEmploymentAsofRow) -> Employment {
  Employment(
    engineer_id: row.engineer_id,
    started: row.started,
    level: row.level,
    monthly_salary: row.monthly_salary,
  )
}

fn role_to_shared(row: sql.EngineerRoleHistoryRow) -> RoleVersion {
  RoleVersion(
    level: row.level,
    valid_from: row.valid_from,
    valid_to: row.valid_to,
  )
}

fn allocation_to_shared(row: sql.EngineerAllocationsRow) -> AllocationRow {
  AllocationRow(
    project_id: row.project_id,
    project: row.project,
    fraction: row.fraction,
    valid_from: row.valid_from,
    valid_to: row.valid_to,
    active: row.active,
  )
}

fn leave_record_to_shared(row: sql.LeaveHistoryRow) -> LeaveRecord {
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
  annual_rows: List(sql.LeaveBalanceRow),
  sick_rows: List(sql.LeaveBalanceRow),
) -> LeaveBalance {
  LeaveBalance(
    engineer: name,
    annual: balance_value(annual_rows),
    sick: balance_value(sick_rows),
  )
}

fn balance_value(rows: List(sql.LeaveBalanceRow)) -> Float {
  case rows {
    [row, ..] -> row.balance
    [] -> 0.0
  }
}
