//// The draft read models and the typed field value round-trip through JSON: a
//// self-describing `FieldValue` per variant, a `DraftView` carrying values and
//// per-step status, and a `DraftSummary` resume row.

import gleam/dict
import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import gleam/time/calendar.{Date, June}
import shared/money
import shared/workflow/value.{
  BoolValue, DateValue, IntValue, MoneyValue, PersonValue, RowsValue, TextValue,
}
import shared/workflow/view.{
  Active, Done, DraftSummary, DraftView, Locked, Pending,
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

fn round_trips(field_value: value.FieldValue) -> Bool {
  let assert Ok(decoded) =
    parse_with(render(value.encode(field_value)), value.decoder())
  decoded == field_value
}

pub fn text_value_round_trips_test() {
  assert round_trips(TextValue("Aisha Okafor")) == True
}

pub fn int_value_round_trips_test() {
  assert round_trips(IntValue(6)) == True
}

pub fn money_value_round_trips_test() {
  let assert Ok(amount) = money.from_string("145000.00")
  assert round_trips(MoneyValue(amount)) == True
}

pub fn date_value_round_trips_test() {
  assert round_trips(DateValue(Date(2026, June, 13))) == True
}

pub fn bool_value_round_trips_test() {
  assert round_trips(BoolValue(True)) == True
}

pub fn person_value_round_trips_test() {
  assert round_trips(PersonValue(42)) == True
}

pub fn draft_round_trips_test() {
  let assert Ok(salary) = money.from_string("145000.00")
  let draft =
    DraftView(
      instance_id: "wf-1",
      kind: "onboard_engineer",
      status: "draft",
      current_step: "employment",
      can_act: True,
      values: dict.from_list([
        #(
          "identity",
          dict.from_list([#("full_name", TextValue("Aisha Okafor"))]),
        ),
        #(
          "employment",
          dict.from_list([
            #("base_salary", MoneyValue(salary)),
            #("start_date", DateValue(Date(2026, June, 13))),
          ]),
        ),
      ]),
      step_status: dict.from_list([
        #("identity", Done),
        #("employment", Active),
        #("banking", Pending),
        #("payroll", Locked),
      ]),
    )

  let assert Ok(decoded) =
    parse_with(render(view.encode_draft(draft)), view.draft_decoder())

  assert decoded == draft
}

pub fn rows_value_round_trips_test() {
  let step_values =
    dict.from_list([
      #(
        "emergency_contacts",
        RowsValue([
          dict.from_list([
            #("name", TextValue("Alice Smith")),
            #("email", TextValue("alice@example.com")),
          ]),
          dict.from_list([
            #("name", TextValue("Bob Jones")),
            #("email", TextValue("bob@example.com")),
          ]),
        ]),
      ),
    ])

  let assert Ok(decoded) =
    json.parse(
      json.to_string(value.encode_step(step_values)),
      value.step_decoder(),
    )

  assert decoded == step_values
}

pub fn summary_round_trips_test() {
  let summary =
    DraftSummary(
      instance_id: "wf-1",
      kind: "onboard_engineer",
      status: "awaiting_finance",
      title: "Onboard Aisha Okafor",
      current_step: "payroll",
      awaiting_me: True,
    )

  let assert Ok(decoded) =
    parse_with(render(view.encode_summary(summary)), view.summary_decoder())

  assert decoded == summary
}
