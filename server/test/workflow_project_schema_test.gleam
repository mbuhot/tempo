//// Tests for the create_project schema: step ordering, client picker sentinel, and
//// the confirm step's permission gate.

import gleam/list
import gleam/option.{Some}
import shared/workflow/schema.{Choice, EnumField}
import tempo/server/workflow/project_schema
import tempo/server/workflow/registry
import test_pool

pub fn schema_kind_is_create_project_test() {
  let assert Ok(schema) = project_schema.create_project_schema(test_pool.ctx())
  assert schema.kind == "create_project"
}

pub fn step_ids_are_in_canonical_order_test() {
  let assert Ok(schema) = project_schema.create_project_schema(test_pool.ctx())
  assert registry.step_ids(schema)
    == ["client", "description", "timeframe", "contract", "confirm"]
}

pub fn confirm_step_requires_project_create_confirm_test() {
  let assert Ok(schema) = project_schema.create_project_schema(test_pool.ctx())
  let assert Ok(confirm) =
    list.find(schema.steps, fn(step) { step.id == "confirm" })
  assert confirm.requires_permission == Some("project.create.confirm")
}

pub fn client_field_first_option_is_new_client_sentinel_test() {
  let assert Ok(schema) = project_schema.create_project_schema(test_pool.ctx())
  let assert Ok(client_step) =
    list.find(schema.steps, fn(step) { step.id == "client" })
  let assert [section] = client_step.sections
  let assert Ok(client_field) =
    list.find(section.fields, fn(field) { field.key == "client" })
  let assert EnumField(options: options) = client_field.kind
  let assert [first, ..] = options
  assert first == Choice("__new__", "+ New client")
}
