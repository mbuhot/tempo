//// Unit tests for the authorization gate and session mapping (issue #6). Pure —
//// no database, no HTTP: `authorize` (Admin runs everything, Ops and Engineer are
//// denied the financial commands), and the `to_session`/`from_session` round-trip
//// that the signed cookie carries.

import gleam/time/calendar
import shared/command.{
  EngineerCommand, PayrollCommand, SalaryCommand, TimesheetCommand,
}
import shared/engineer/command as engineer_command
import shared/money.{type Money}
import shared/payroll/command as payroll_command
import shared/salary/command as salary_command
import shared/timesheet/command as timesheet_command
import tempo/server/auth.{Admin, Engineer, Forbidden, Ops, Principal}

fn date() -> calendar.Date {
  calendar.Date(2026, calendar.June, 15)
}

fn money_of(text: String) -> Money {
  let assert Ok(amount) = money.from_string(text)
  amount
}

// Admin may run a financial command.
pub fn admin_may_run_financial_command_test() {
  let principal = Principal(actor: "Admin", role: Admin)
  assert auth.authorize(
      principal,
      SalaryCommand(salary_command.SetSalary(5, money_of("12000.00"), date())),
    )
    == Ok("Admin")
}

// Ops is denied the financial commands but may run the rest.
pub fn ops_is_denied_financial_but_allowed_operational_test() {
  let principal = Principal(actor: "Ops", role: Ops)
  assert auth.authorize(
      principal,
      PayrollCommand(payroll_command.RunPayroll(date(), date())),
    )
    == Error(Forbidden(actor: "Ops", command: "run_payroll"))
  assert auth.authorize(
      principal,
      TimesheetCommand(timesheet_command.LogTimesheet(
        engineer_id: 2,
        project_id: 300,
        day: date(),
        hours: 7.5,
      )),
    )
    == Ok("Ops")
}

// An engineer is denied a financial command too (only Admin moves money).
pub fn engineer_is_denied_financial_command_test() {
  let principal = Principal(actor: "Priya Sharma", role: Engineer)
  assert auth.authorize(
      principal,
      SalaryCommand(salary_command.SetSalary(5, money_of("12000.00"), date())),
    )
    == Error(Forbidden(actor: "Priya Sharma", command: "set_salary"))
  assert auth.authorize(
      principal,
      EngineerCommand(engineer_command.Promote(
        engineer_id: 2,
        level: 6,
        effective: date(),
      )),
    )
    == Ok("Priya Sharma")
}

// A session round-trips: a principal serialized to its cookie payload parses back
// to the same principal.
pub fn session_round_trips_test() {
  let principal = Principal(actor: "Ops", role: Ops)
  let session = auth.to_session(principal)
  assert auth.from_session(session) == Ok(principal)
}

// The cookie is signed, so a well-formed payload that verified is trusted as-is —
// the actor and role are taken from it without a registry lookup.
pub fn session_trusts_a_well_formed_signed_payload_test() {
  assert auth.from_session("Priya Sharma|engineer")
    == Ok(Principal(actor: "Priya Sharma", role: Engineer))
}

// A malformed payload is rejected: no separator, an empty actor, or an unknown role.
pub fn session_rejects_a_malformed_payload_test() {
  assert auth.from_session("garbage") == Error(Nil)
  assert auth.from_session("Admin|wizard") == Error(Nil)
  assert auth.from_session("|admin") == Error(Nil)
}

// The role wire-string maps both ways; an unknown role string is an error.
pub fn role_from_string_maps_known_roles_test() {
  assert auth.role_from_string("admin") == Ok(Admin)
  assert auth.role_from_string("ops") == Ok(Ops)
  assert auth.role_from_string("engineer") == Ok(Engineer)
  assert auth.role_from_string("wizard") == Error(Nil)
}
