//// The generic step renderer: a step becomes a list of section cards, each a fieldset
//// laid out by its `Layout`, each field a control chosen exhaustively on `FieldType`.
//// It raises two events — `Edited` per keystroke (the page updates its local buffer)
//// and `Committed` on blur/change (the page saves). Adding a `FieldType` variant fails
//// the build here until its control is added.

import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/list
import gleam/result
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import shared/workflow/schema.{
  type Field, type Section, type Step, BoolField, DateField, EmailField,
  EnumField, IntField, MoneyField, OneColumn, PersonField, TextField, TwoColumn,
}

/// A field interaction. `Edited` carries each keystroke so the page updates its input
/// buffer without saving; `Committed` (blur, or change for select/checkbox) tells the
/// page to persist the value.
pub type FieldEvent {
  Edited(step: String, field: String, raw: String)
  Committed(step: String, field: String, raw: String)
}

/// Render one step: its sections as cards. `display` maps each field key to the string
/// currently shown (the page's edit buffer merged over the saved value).
pub fn step_view(
  step: Step,
  display: Dict(String, String),
  on_event: fn(FieldEvent) -> msg,
) -> Element(msg) {
  html.div(
    [attribute.class("wizard__sections")],
    list.map(step.sections, fn(section) {
      section_card(step.id, section, display, on_event)
    }),
  )
}

fn section_card(
  step_id: String,
  section: Section,
  display: Dict(String, String),
  on_event: fn(FieldEvent) -> msg,
) -> Element(msg) {
  let layout_class = case section.layout {
    OneColumn -> "wizard__fields wizard__fields--one"
    TwoColumn -> "wizard__fields wizard__fields--two"
  }
  html.section([attribute.class("wizard__card")], [
    html.h3([attribute.class("wizard__card-title")], [html.text(section.title)]),
    html.div(
      [attribute.class(layout_class)],
      list.map(section.fields, fn(field) {
        field_view(step_id, field, display, on_event)
      }),
    ),
  ])
}

fn field_view(
  step_id: String,
  field: Field,
  display: Dict(String, String),
  on_event: fn(FieldEvent) -> msg,
) -> Element(msg) {
  let current = dict.get(display, field.key) |> result.unwrap("")
  html.label([attribute.class("op-form__field")], [
    html.span([], [html.text(field_label(field))]),
    control(step_id, field, current, on_event),
  ])
}

fn field_label(field: Field) -> String {
  case field.required {
    True -> field.label <> " *"
    False -> field.label
  }
}

fn control(
  step_id: String,
  field: Field,
  current: String,
  on_event: fn(FieldEvent) -> msg,
) -> Element(msg) {
  case field.kind {
    TextField -> text_control(step_id, field, current, "text", on_event)
    EmailField -> text_control(step_id, field, current, "email", on_event)
    IntField -> text_control(step_id, field, current, "number", on_event)
    PersonField -> text_control(step_id, field, current, "number", on_event)
    MoneyField -> text_control(step_id, field, current, "text", on_event)
    DateField -> text_control(step_id, field, current, "date", on_event)
    EnumField(options:) -> select_control(step_id, field, current, options, on_event)
    BoolField -> checkbox_control(step_id, field, current, on_event)
  }
}

fn text_control(
  step_id: String,
  field: Field,
  current: String,
  input_type: String,
  on_event: fn(FieldEvent) -> msg,
) -> Element(msg) {
  html.input([
    attribute.type_(input_type),
    attribute.attribute("aria-label", field.label),
    attribute.value(current),
    event.on_input(fn(value) { on_event(Edited(step_id, field.key, value)) }),
    on_blur(on_event(Committed(step_id, field.key, current))),
  ])
}

fn select_control(
  step_id: String,
  field: Field,
  current: String,
  options: List(schema.Choice),
  on_event: fn(FieldEvent) -> msg,
) -> Element(msg) {
  let placeholder =
    html.option([attribute.value(""), attribute.selected(current == "")], "—")
  let choices =
    list.map(options, fn(choice) {
      html.option(
        [attribute.value(choice.value), attribute.selected(choice.value == current)],
        choice.label,
      )
    })
  html.select(
    [
      attribute.attribute("aria-label", field.label),
      event.on_change(fn(value) {
        on_event(Committed(step_id, field.key, value))
      }),
    ],
    [placeholder, ..choices],
  )
}

fn checkbox_control(
  step_id: String,
  field: Field,
  current: String,
  on_event: fn(FieldEvent) -> msg,
) -> Element(msg) {
  html.input([
    attribute.type_("checkbox"),
    attribute.attribute("aria-label", field.label),
    attribute.checked(current == "true"),
    event.on_check(fn(checked) {
      on_event(Committed(step_id, field.key, bool_to_string(checked)))
    }),
  ])
}

fn bool_to_string(checked: Bool) -> String {
  case checked {
    True -> "true"
    False -> "false"
  }
}

fn on_blur(msg: msg) -> attribute.Attribute(msg) {
  event.on("blur", decode.success(msg))
}
