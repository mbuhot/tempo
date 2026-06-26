//// Unit tests for the permission-based authorization gate (issue #6). Pure — no
//// database, no HTTP: `authorize` checks a command against a principal's permission set,
//// the ownership pairs scope `.own` to the principal's own engineer, and
//// `can_read_engineer` allows `read.engineers` or one's own record.

import gleam/option.{type Option, None, Some}
import gleam/set
import gleam/time/calendar
import shared/access
import shared/command.{
  EngineerCommand, EngineerDetailsCommand, PayrollCommand, SalaryCommand,
}
import shared/engineer/command as engineer_command
import shared/engineer_details/command as engineer_details_command
import shared/money.{type Money}
import shared/payroll/command as payroll_command
import shared/salary/command as salary_command
import tempo/server/auth.{type Principal, Forbidden, Principal}

fn date() -> calendar.Date {
  calendar.Date(2026, calendar.June, 15)
}

fn money_of(text: String) -> Money {
  let assert Ok(amount) = money.from_string(text)
  amount
}

fn principal_with(
  permissions: List(String),
  engineer_id: Option(Int),
) -> Principal {
  Principal(
    account_id: 1,
    actor: "Test",
    engineer_id:,
    permissions: set.from_list(permissions),
  )
}

fn update_contact(engineer_id: Int) -> command.Command {
  EngineerDetailsCommand(engineer_details_command.UpdateContactDetails(
    engineer_id:,
    name: "A",
    email: "a@x",
    phone: "1",
    postal_address: "addr",
    effective: date(),
  ))
}

// A command runs only when the principal holds its required permission.
pub fn authorize_requires_the_commands_permission_test() {
  let promote =
    EngineerCommand(engineer_command.Promote(
      engineer_id: 2,
      level: 6,
      effective: date(),
    ))
  assert auth.authorize(
      principal_with([access.engineer_promote], None),
      promote,
    )
    == Ok("Test")
  assert auth.authorize(principal_with([], None), promote)
    == Error(Forbidden(actor: "Test", command: "promote"))
}

// The four financial commands key on distinct permissions, so a manager-style set
// (no money permissions) is refused payroll and salary.
pub fn financial_commands_need_their_own_permissions_test() {
  let payroll = PayrollCommand(payroll_command.RunPayroll(date(), date()))
  let salary =
    SalaryCommand(salary_command.SetSalary(5, money_of("12000.00"), date()))
  assert auth.authorize(principal_with([access.payroll_run], None), payroll)
    == Ok("Test")
  assert auth.authorize(principal_with([access.salary_set], None), salary)
    == Ok("Test")
  assert auth.authorize(principal_with([access.payroll_run], None), salary)
    == Error(Forbidden(actor: "Test", command: "set_salary"))
}

// profile.update is ownership-scoped: `.own` lets the engineer edit their OWN record
// but not another's; `.any` edits anyone's.
pub fn profile_update_is_ownership_scoped_test() {
  let own_set = principal_with([access.profile_update_own], Some(5))
  assert auth.authorize(own_set, update_contact(5)) == Ok("Test")
  assert auth.authorize(own_set, update_contact(9))
    == Error(Forbidden(actor: "Test", command: "update_profile"))

  let any_set = principal_with([access.profile_update_any], None)
  assert auth.authorize(any_set, update_contact(9)) == Ok("Test")
}

// can_read_engineer: anyone with read.engineers reads any engineer; otherwise only one's
// own record.
pub fn can_read_engineer_allows_any_with_permission_or_own_test() {
  assert auth.can_read_engineer(
    principal_with([access.read_engineers], None),
    9,
  )
  assert !auth.can_read_engineer(principal_with([], Some(5)), 9)
  assert auth.can_read_engineer(principal_with([], Some(5)), 5)
}
