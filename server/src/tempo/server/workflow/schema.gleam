//// The Phase-1 onboarding flow as a pure value. Fixed in Gleam (Phase 2 lifts it
//// into the database). Every field maps to a fact the commit writes, so the wizard
//// never gathers data with nowhere to land: identity + level + start date + contact
//// + banking become the engineer's employment, role, contact and banking facts; the
//// final payroll step is gated to Finance and gates the commit.

import gleam/int
import gleam/list
import gleam/option.{None, Some}
import shared/access
import shared/level
import shared/workflow/schema.{
  type Choice, type FieldType, type WorkflowSchema, BoolField, Choice, DateField,
  EmailField, EnumField, Field, OneColumn, Section, Step, TextField, TwoColumn,
  WorkflowSchema,
}

/// The workflow kind tag stored on every onboarding instance.
pub const kind = "onboard_engineer"

/// The id of the first step, where a fresh instance opens.
pub const first_step = "identity"

/// The Phase-1 onboard-engineer schema: the ordered steps the client renders.
pub fn onboard_schema() -> WorkflowSchema {
  WorkflowSchema(kind:, title: "Onboard engineer", steps: [
    Step(
      id: "identity",
      title: "Identity",
      requires_permission: None,
      sections: [
        Section(title: "", layout: TwoColumn, fields: [
          Field(
            "full_name",
            "Full name",
            TextField,
            True,
            Some("As it appears on the contract"),
          ),
          Field("work_email", "Work email", EmailField, True, None),
        ]),
      ],
    ),
    Step(id: "level", title: "Level", requires_permission: None, sections: [
      Section(title: "", layout: OneColumn, fields: [
        Field("level", "Level", EnumField(options: level_options()), True, None),
      ]),
    ]),
    Step(
      id: "employment",
      title: "Employment",
      requires_permission: None,
      sections: [
        Section(title: "", layout: OneColumn, fields: [
          Field(
            "start_date",
            "Start date",
            DateField,
            True,
            Some("The first day of employment"),
          ),
        ]),
      ],
    ),
    Step(id: "contact", title: "Contact", requires_permission: None, sections: [
      Section(title: "", layout: OneColumn, fields: [
        Field("phone", "Phone", TextField, False, None),
        Field("postal_address", "Postal address", TextField, False, None),
      ]),
    ]),
    Step(
      id: "emergency",
      title: "Emergency",
      requires_permission: None,
      sections: [
        Section(title: "", layout: TwoColumn, fields: [
          Field("emergency_name", "Contact name", TextField, False, None),
          Field(
            "emergency_relation",
            "Relationship",
            TextField,
            False,
            Some("e.g. spouse, parent"),
          ),
          Field("emergency_phone", "Phone", TextField, False, None),
          Field("emergency_email", "Email", EmailField, False, None),
        ]),
      ],
    ),
    Step(id: "banking", title: "Banking", requires_permission: None, sections: [
      Section(title: "", layout: TwoColumn, fields: [
        Field("bank", "Bank", TextField, True, None),
        Field("branch", "Branch", TextField, False, None),
        Field("account_no", "Account number", TextField, True, None),
        Field("account_name", "Account name", TextField, True, None),
      ]),
    ]),
    Step(
      id: "payroll",
      title: "Payroll",
      requires_permission: Some(access.engineer_onboard_commit),
      sections: [
        Section(title: "", layout: OneColumn, fields: [
          Field(
            "payroll_confirmed",
            "Payroll details entered externally",
            BoolField,
            True,
            Some(
              "Finance confirms the engineer is set up for pay before commit",
            ),
          ),
        ]),
      ],
    ),
  ])
}

/// The ordered step ids, for advancing the wizard and computing step status.
pub fn step_ids() -> List(String) {
  onboard_schema().steps |> list.map(fn(step) { step.id })
}

/// The id of the first permission-gated step — the Finance step a hand-off advances
/// to. Falls back to the first step if none is gated.
pub fn finance_step() -> String {
  let gated =
    list.filter(onboard_schema().steps, fn(step) {
      case step.requires_permission {
        Some(_) -> True
        None -> False
      }
    })
  case gated {
    [step, ..] -> step.id
    [] -> first_step
  }
}

/// The type of a field addressed by step id + field key, or `Error` if no such
/// field exists in the schema (the commit/save path rejects unknown keys).
pub fn field_type(
  step_id: String,
  field_key: String,
) -> Result(FieldType, Nil) {
  use step <- result_then(
    list.find(onboard_schema().steps, fn(step) { step.id == step_id }),
  )
  let fields = list.flat_map(step.sections, fn(section) { section.fields })
  list.find(fields, fn(field) { field.key == field_key })
  |> result_map(fn(field) { field.kind })
}

fn level_options() -> List(Choice) {
  [1, 2, 3, 4, 5, 6, 7]
  |> list.map(fn(rank) { Choice(int.to_string(rank), level.band(rank)) })
}

fn result_then(
  result: Result(a, e),
  apply: fn(a) -> Result(b, e),
) -> Result(b, e) {
  case result {
    Ok(value) -> apply(value)
    Error(error) -> Error(error)
  }
}

fn result_map(result: Result(a, e), apply: fn(a) -> b) -> Result(b, e) {
  case result {
    Ok(value) -> Ok(apply(value))
    Error(error) -> Error(error)
  }
}
