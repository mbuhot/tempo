//// The fixed onboard schema: the steps appear in order, the payroll step is gated
//// to Finance, and a field's type resolves by step + key.

import gleam/list
import gleam/option.{None, Some}
import shared/access
import shared/workflow/schema.{TextField}
import tempo/server/workflow/schema as flow

pub fn onboard_steps_in_order_test() {
  assert flow.step_ids()
    == ["identity", "level", "employment", "contact", "banking", "payroll"]
}

pub fn payroll_step_is_finance_gated_test() {
  let assert Ok(payroll) =
    list.find(flow.onboard_schema().steps, fn(step) { step.id == "payroll" })

  assert payroll.requires_permission == Some(access.engineer_onboard_commit)
}

pub fn earlier_steps_are_ungated_test() {
  let assert Ok(identity) =
    list.find(flow.onboard_schema().steps, fn(step) { step.id == "identity" })

  assert identity.requires_permission == None
}

pub fn field_type_resolves_by_step_and_key_test() {
  assert flow.field_type("identity", "full_name") == Ok(TextField)
}

pub fn unknown_field_is_an_error_test() {
  assert flow.field_type("identity", "nope") == Error(Nil)
}
