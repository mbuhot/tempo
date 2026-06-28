//// A workflow's shape, server-driven like the data-table schema: an ordered list
//// of steps, each a list of titled sections, each a list of typed fields. The
//// client renders this generically. `FieldType` is the source of truth the client
//// switches on to render and validate a field; every `case` over it is exhaustive,
//// so adding a variant fails the build until each site handles it.

import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import gleam/option.{type Option, None}

/// A choice offered by an `EnumField`: the stored `value` and its display `label`.
pub type Choice {
  Choice(value: String, label: String)
}

/// The typed kind of a field. Mirrors the table system's `Cell`/`ColumnType`
/// vocabulary so the two renderers share a mental model.
pub type FieldType {
  TextField
  EmailField
  IntField
  MoneyField
  DateField
  EnumField(options: List(Choice))
  PersonField
  BoolField
}

/// How a section lays its fields out: a single column or a two-column grid.
pub type Layout {
  OneColumn
  TwoColumn
}

/// One typed input. `key` is unique within its step; `required` drives client-side
/// formatting validation; `help` is optional guidance shown under the label.
pub type Field {
  Field(
    key: String,
    label: String,
    kind: FieldType,
    required: Bool,
    help: Option(String),
  )
}

/// A titled group of fields the renderer draws as one card.
pub type Section {
  Section(title: String, layout: Layout, fields: List(Field))
}

/// One screen of the wizard. `requires_permission` gates the step to a role (e.g.
/// the Finance-only payroll confirmation); `None` means any owner may complete it.
pub type Step {
  Step(
    id: String,
    title: String,
    sections: List(Section),
    requires_permission: Option(String),
  )
}

/// A whole workflow: its `kind` (e.g. "onboard_engineer"), a display `title`, and
/// the ordered steps.
pub type WorkflowSchema {
  WorkflowSchema(kind: String, title: String, steps: List(Step))
}

pub fn field_type_to_string(kind: FieldType) -> String {
  case kind {
    TextField -> "text"
    EmailField -> "email"
    IntField -> "int"
    MoneyField -> "money"
    DateField -> "date"
    EnumField(..) -> "enum"
    PersonField -> "person"
    BoolField -> "bool"
  }
}

fn layout_to_string(layout: Layout) -> String {
  case layout {
    OneColumn -> "one"
    TwoColumn -> "two"
  }
}

fn layout_from_string(text: String) -> Layout {
  case text {
    "two" -> TwoColumn
    _ -> OneColumn
  }
}

pub fn encode_schema(schema: WorkflowSchema) -> Json {
  json.object([
    #("kind", json.string(schema.kind)),
    #("title", json.string(schema.title)),
    #("steps", json.array(schema.steps, encode_step)),
  ])
}

fn encode_step(step: Step) -> Json {
  json.object([
    #("id", json.string(step.id)),
    #("title", json.string(step.title)),
    #("sections", json.array(step.sections, encode_section)),
    #(
      "requires_permission",
      json.nullable(step.requires_permission, json.string),
    ),
  ])
}

fn encode_section(section: Section) -> Json {
  json.object([
    #("title", json.string(section.title)),
    #("layout", json.string(layout_to_string(section.layout))),
    #("fields", json.array(section.fields, encode_field)),
  ])
}

fn encode_field(field: Field) -> Json {
  json.object([
    #("key", json.string(field.key)),
    #("label", json.string(field.label)),
    #("kind", encode_field_type(field.kind)),
    #("required", json.bool(field.required)),
    #("help", json.nullable(field.help, json.string)),
  ])
}

fn encode_field_type(kind: FieldType) -> Json {
  case kind {
    EnumField(options:) ->
      json.object([
        #("type", json.string("enum")),
        #("options", json.array(options, encode_choice)),
      ])
    other -> json.object([#("type", json.string(field_type_to_string(other)))])
  }
}

fn encode_choice(choice: Choice) -> Json {
  json.object([
    #("value", json.string(choice.value)),
    #("label", json.string(choice.label)),
  ])
}

pub fn schema_decoder() -> Decoder(WorkflowSchema) {
  use kind <- decode.field("kind", decode.string)
  use title <- decode.field("title", decode.string)
  use steps <- decode.field("steps", decode.list(step_decoder()))
  decode.success(WorkflowSchema(kind:, title:, steps:))
}

fn step_decoder() -> Decoder(Step) {
  use id <- decode.field("id", decode.string)
  use title <- decode.field("title", decode.string)
  use sections <- decode.field("sections", decode.list(section_decoder()))
  use requires_permission <- decode.optional_field(
    "requires_permission",
    None,
    decode.optional(decode.string),
  )
  decode.success(Step(id:, title:, sections:, requires_permission:))
}

fn section_decoder() -> Decoder(Section) {
  use title <- decode.field("title", decode.string)
  use layout_text <- decode.field("layout", decode.string)
  use fields <- decode.field("fields", decode.list(field_decoder()))
  decode.success(Section(
    title:,
    layout: layout_from_string(layout_text),
    fields:,
  ))
}

fn field_decoder() -> Decoder(Field) {
  use key <- decode.field("key", decode.string)
  use label <- decode.field("label", decode.string)
  use kind <- decode.field("kind", field_type_decoder())
  use required <- decode.field("required", decode.bool)
  use help <- decode.optional_field(
    "help",
    None,
    decode.optional(decode.string),
  )
  decode.success(Field(key:, label:, kind:, required:, help:))
}

pub fn field_type_decoder() -> Decoder(FieldType) {
  use type_text <- decode.field("type", decode.string)
  case type_text {
    "enum" -> {
      use options <- decode.field("options", decode.list(choice_decoder()))
      decode.success(EnumField(options:))
    }
    "email" -> decode.success(EmailField)
    "int" -> decode.success(IntField)
    "money" -> decode.success(MoneyField)
    "date" -> decode.success(DateField)
    "person" -> decode.success(PersonField)
    "bool" -> decode.success(BoolField)
    _ -> decode.success(TextField)
  }
}

fn choice_decoder() -> Decoder(Choice) {
  use value <- decode.field("value", decode.string)
  use label <- decode.field("label", decode.string)
  decode.success(Choice(value:, label:))
}
