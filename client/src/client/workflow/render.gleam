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
  EnumField, GroupField, IntField, MoneyField, OneColumn, PersonField, TextField,
  TwoColumn,
}

/// A field interaction. `Edited` carries each keystroke so the page updates its input
/// buffer without saving; `Committed` (blur, or change for select/checkbox) tells the
/// page to persist the value. The `RowAdded`, `RowRemoved`, and `RowFieldEdited`
/// variants manage repeating-group rows.
pub type FieldEvent {
  Edited(step: String, field: String, raw: String)
  Committed(step: String, field: String, raw: String)
  RowAdded(step: String, field: String)
  RowRemoved(step: String, field: String, index: Int)
  RowFieldEdited(
    step: String,
    field: String,
    index: Int,
    item_key: String,
    raw: String,
  )
  RowFieldChanged(
    step: String,
    field: String,
    index: Int,
    item_key: String,
    raw: String,
  )
}

/// Render one step: its sections as cards. `display` maps each field key to the string
/// currently shown (the page's edit buffer merged over the saved value). `groups` maps
/// each group field key to its list of row display maps.
pub fn step_view(
  step: Step,
  display: Dict(String, String),
  groups: Dict(String, List(Dict(String, String))),
  on_event: fn(FieldEvent) -> msg,
) -> Element(msg) {
  html.div(
    [attribute.class("wizard__sections")],
    list.map(step.sections, fn(section) {
      section_card(step.id, section, display, groups, on_event)
    }),
  )
}

fn section_card(
  step_id: String,
  section: Section,
  display: Dict(String, String),
  groups: Dict(String, List(Dict(String, String))),
  on_event: fn(FieldEvent) -> msg,
) -> Element(msg) {
  let layout_class = case section.layout {
    OneColumn -> "wizard__fields wizard__fields--one"
    TwoColumn -> "wizard__fields wizard__fields--two"
  }
  html.section([attribute.class("wizard__card")], [
    section_title(section.title),
    html.div(
      [attribute.class(layout_class)],
      list.map(section.fields, fn(field) {
        field_view(step_id, field, display, groups, on_event)
      }),
    ),
  ])
}

/// A section's heading, shown only when it carries one. A single-section step needs
/// no title — the step heading already names it.
fn section_title(title: String) -> Element(msg) {
  case title {
    "" -> element.none()
    _ -> html.h3([attribute.class("wizard__card-title")], [html.text(title)])
  }
}

fn field_view(
  step_id: String,
  field: Field,
  display: Dict(String, String),
  groups: Dict(String, List(Dict(String, String))),
  on_event: fn(FieldEvent) -> msg,
) -> Element(msg) {
  let current = dict.get(display, field.key) |> result.unwrap("")
  case field.kind {
    BoolField ->
      html.label([attribute.class("op-form__check")], [
        checkbox_control(step_id, field, current, on_event),
        html.span([], [html.text(field.label)]),
      ])
    GroupField(item_fields:, add_label:) ->
      html.div([attribute.class("op-form__field")], [
        html.span([], [html.text(field_label(field))]),
        group_view(step_id, field, item_fields, add_label, groups, on_event),
      ])
    _ ->
      html.label([attribute.class("op-form__field")], [
        html.span([], [html.text(field_label(field))]),
        control(step_id, field, current, on_event),
      ])
  }
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
    EnumField(options:) ->
      select_control(step_id, field, current, options, on_event)
    BoolField -> checkbox_control(step_id, field, current, on_event)
    GroupField(..) -> element.none()
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
    commit_on_blur(step_id, field.key, on_event),
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
        [
          attribute.value(choice.value),
          attribute.selected(choice.value == current),
        ],
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

/// Commit on blur, reading the field's LIVE value from the event target (not a value
/// captured at render time — that would persist a stale value, since the handler is
/// built once per render).
fn commit_on_blur(
  step_id: String,
  field_key: String,
  on_event: fn(FieldEvent) -> msg,
) -> attribute.Attribute(msg) {
  event.on(
    "blur",
    decode.at(["target", "value"], decode.string)
      |> decode.map(fn(value) { on_event(Committed(step_id, field_key, value)) }),
  )
}

fn group_view(
  step_id: String,
  field: Field,
  item_fields: List(schema.Field),
  add_label: String,
  groups: Dict(String, List(Dict(String, String))),
  on_event: fn(FieldEvent) -> msg,
) -> Element(msg) {
  let rows = dict.get(groups, field.key) |> result.unwrap([])
  html.div(
    [attribute.class("wizard__group")],
    list.append(
      list.index_map(rows, fn(row, index) {
        group_row_view(step_id, field.key, index, item_fields, row, on_event)
      }),
      [
        html.button(
          [
            attribute.class("wizard__group-add"),
            attribute.type_("button"),
            event.on_click(on_event(RowAdded(step_id, field.key))),
          ],
          [html.text("+ " <> add_label)],
        ),
      ],
    ),
  )
}

fn group_row_view(
  step_id: String,
  field_key: String,
  index: Int,
  item_fields: List(schema.Field),
  row: Dict(String, String),
  on_event: fn(FieldEvent) -> msg,
) -> Element(msg) {
  let item_controls =
    list.map(item_fields, fn(item_field) {
      let current = dict.get(row, item_field.key) |> result.unwrap("")
      html.label([attribute.class("op-form__field")], [
        html.span([], [html.text(item_field.label)]),
        group_item_control(
          step_id,
          field_key,
          index,
          item_field,
          current,
          on_event,
        ),
      ])
    })
  let remove_btn =
    html.button(
      [
        attribute.class("wizard__group-remove"),
        attribute.type_("button"),
        event.on_click(on_event(RowRemoved(step_id, field_key, index))),
      ],
      [html.text("Remove")],
    )
  html.div(
    [attribute.class("wizard__group-row")],
    list.append(item_controls, [remove_btn]),
  )
}

fn group_item_control(
  step_id: String,
  field_key: String,
  index: Int,
  item_field: schema.Field,
  current: String,
  on_event: fn(FieldEvent) -> msg,
) -> Element(msg) {
  case item_field.kind {
    TextField ->
      group_text_input(
        step_id,
        field_key,
        index,
        item_field,
        current,
        "text",
        on_event,
      )
    EmailField ->
      group_text_input(
        step_id,
        field_key,
        index,
        item_field,
        current,
        "email",
        on_event,
      )
    IntField ->
      group_text_input(
        step_id,
        field_key,
        index,
        item_field,
        current,
        "number",
        on_event,
      )
    PersonField ->
      group_text_input(
        step_id,
        field_key,
        index,
        item_field,
        current,
        "number",
        on_event,
      )
    MoneyField ->
      group_text_input(
        step_id,
        field_key,
        index,
        item_field,
        current,
        "text",
        on_event,
      )
    DateField ->
      group_text_input(
        step_id,
        field_key,
        index,
        item_field,
        current,
        "date",
        on_event,
      )
    EnumField(options:) ->
      group_select(
        step_id,
        field_key,
        index,
        item_field,
        current,
        options,
        on_event,
      )
    BoolField ->
      group_checkbox(step_id, field_key, index, item_field, current, on_event)
    GroupField(..) -> element.none()
  }
}

fn group_text_input(
  step_id: String,
  field_key: String,
  index: Int,
  item_field: schema.Field,
  current: String,
  input_type: String,
  on_event: fn(FieldEvent) -> msg,
) -> Element(msg) {
  html.input([
    attribute.type_(input_type),
    attribute.attribute("aria-label", item_field.label),
    attribute.value(current),
    event.on_input(fn(raw) {
      on_event(RowFieldChanged(step_id, field_key, index, item_field.key, raw))
    }),
    event.on(
      "blur",
      decode.at(["target", "value"], decode.string)
        |> decode.map(fn(raw) {
          on_event(RowFieldEdited(
            step_id,
            field_key,
            index,
            item_field.key,
            raw,
          ))
        }),
    ),
  ])
}

fn group_select(
  step_id: String,
  field_key: String,
  index: Int,
  item_field: schema.Field,
  current: String,
  options: List(schema.Choice),
  on_event: fn(FieldEvent) -> msg,
) -> Element(msg) {
  let placeholder =
    html.option([attribute.value(""), attribute.selected(current == "")], "—")
  let choices =
    list.map(options, fn(choice) {
      html.option(
        [
          attribute.value(choice.value),
          attribute.selected(choice.value == current),
        ],
        choice.label,
      )
    })
  html.select(
    [
      attribute.attribute("aria-label", item_field.label),
      event.on_change(fn(value) {
        on_event(RowFieldEdited(
          step_id,
          field_key,
          index,
          item_field.key,
          value,
        ))
      }),
    ],
    [placeholder, ..choices],
  )
}

fn group_checkbox(
  step_id: String,
  field_key: String,
  index: Int,
  item_field: schema.Field,
  current: String,
  on_event: fn(FieldEvent) -> msg,
) -> Element(msg) {
  html.input([
    attribute.type_("checkbox"),
    attribute.attribute("aria-label", item_field.label),
    attribute.checked(current == "true"),
    event.on_check(fn(checked) {
      on_event(RowFieldEdited(
        step_id,
        field_key,
        index,
        item_field.key,
        bool_to_string(checked),
      ))
    }),
  ])
}
