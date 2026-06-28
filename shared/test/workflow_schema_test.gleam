//// The workflow schema contract: a steps -> sections -> typed fields tree that
//// round-trips through JSON to prove its wire shape, including an enum field's
//// options and a permission-gated step.

import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import gleam/option.{None, Some}
import shared/workflow/schema.{
  Choice, EnumField, Field, MoneyField, OneColumn, Section, Step, TextField,
  TwoColumn, WorkflowSchema,
}

fn render(value: Json) -> String {
  json.to_string(value)
}

fn parse_with(
  text: String,
  decoder: Decoder(a),
) -> Result(a, json.DecodeError) {
  json.parse(text, decoder)
}

pub fn schema_round_trips_test() {
  let schema =
    WorkflowSchema(kind: "onboard_engineer", title: "Onboard engineer", steps: [
      Step(
        id: "identity",
        title: "Identity",
        requires_permission: None,
        sections: [
          Section(title: "Name", layout: TwoColumn, fields: [
            Field(
              key: "full_name",
              label: "Full name",
              kind: TextField,
              required: True,
              help: Some("As it appears on the contract"),
            ),
          ]),
        ],
      ),
      Step(
        id: "employment",
        title: "Employment",
        requires_permission: Some("confirm_onboarding_payroll"),
        sections: [
          Section(title: "Engagement", layout: OneColumn, fields: [
            Field(
              key: "employment_type",
              label: "Employment type",
              kind: EnumField(options: [
                Choice(value: "full_time", label: "Full-time"),
                Choice(value: "contract", label: "Contract"),
              ]),
              required: True,
              help: None,
            ),
            Field(
              key: "base_salary",
              label: "Base salary",
              kind: MoneyField,
              required: True,
              help: None,
            ),
          ]),
        ],
      ),
    ])

  let assert Ok(decoded) =
    parse_with(render(schema.encode_schema(schema)), schema.schema_decoder())

  assert decoded == schema
}
