import tempo/server/workflow/registry
import tempo/server/workflow/schema as onboard

pub fn step_ids_come_from_schema_test() {
  let schema = onboard.onboard_schema()
  assert registry.step_ids(schema) == onboard.step_ids()
}

pub fn first_step_is_first_test() {
  let schema = onboard.onboard_schema()
  assert registry.first_step(schema) == "identity"
}

pub fn finance_step_is_the_gated_step_test() {
  let schema = onboard.onboard_schema()
  assert registry.finance_step(schema) == "payroll"
}
