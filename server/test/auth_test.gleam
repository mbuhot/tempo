//// Unit tests for the authorization gate and session mapping (issue #6). Pure —
//// no database, no HTTP: the registry, `authorize` (Admin runs everything, Ops and
//// Engineer are denied the financial commands), and the `to_session`/`from_session`
//// round-trip that the signed cookie carries.

import gleam/time/calendar
import shared/types.{
  EngineerCommand, LogTimesheet, Promote, RunPayroll, SetSalary,
  TimesheetCommand,
}
import tempo/server/auth.{Admin, Engineer, Forbidden, Ops, Principal}

fn date() -> calendar.Date {
  calendar.Date(2026, calendar.June, 15)
}

// A known identity resolves to its principal; a free-text actor does not.
pub fn lookup_resolves_known_identity_test() {
  assert auth.lookup("Admin") == Ok(Principal(actor: "Admin", role: Admin))
  assert auth.lookup("Priya Sharma")
    == Ok(Principal(actor: "Priya Sharma", role: Engineer))
  assert auth.lookup("nobody") == Error(Nil)
}

// Admin may run a financial command.
pub fn admin_may_run_financial_command_test() {
  let principal = Principal(actor: "Admin", role: Admin)
  assert auth.authorize(principal, SetSalary(5, 12_000.0, date()))
    == Ok("Admin")
}

// Ops is denied the financial commands but may run the rest.
pub fn ops_is_denied_financial_but_allowed_operational_test() {
  let principal = Principal(actor: "Ops", role: Ops)
  assert auth.authorize(principal, RunPayroll(date(), date()))
    == Error(Forbidden(actor: "Ops", command: "run_payroll"))
  assert auth.authorize(
      principal,
      TimesheetCommand(LogTimesheet(
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
  assert auth.authorize(principal, SetSalary(5, 12_000.0, date()))
    == Error(Forbidden(actor: "Priya Sharma", command: "set_salary"))
  assert auth.authorize(
      principal,
      EngineerCommand(Promote(engineer_id: 2, level: 6, effective: date())),
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

// A session for an unknown actor, or a tampered role, is rejected.
pub fn session_rejects_unknown_or_mismatched_test() {
  assert auth.from_session("Mallory|admin") == Error(Nil)
  assert auth.from_session("Ops|admin") == Error(Nil)
  assert auth.from_session("garbage") == Error(Nil)
}
