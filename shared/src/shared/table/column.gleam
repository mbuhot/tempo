//// A table column's schema: its key, label, semantic data-type, alignment,
//// whether it sorts, whether it can be hidden, and (optionally) the filter the
//// server offers for it. The `ColumnType` union is the source of truth the client
//// switches on to render and decode; every `case` over it is exhaustive, so adding
//// a variant fails the build until each site handles it.

import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import gleam/option.{type Option}
import shared/table/filter.{type FilterKind}
import shared/table/sort.{type Sort}

pub type ColumnType {
  TextType
  NumberType
  MoneyType
  DateType
  EnumType
  EntityType
  PersonType
  ChipsType
  BoolType
}

pub type Tone {
  Neutral
  Accent
  Positive
  Warning
  Critical
}

pub type Align {
  Start
  NumericEnd
}

pub type Column {
  Column(
    key: String,
    label: String,
    column_type: ColumnType,
    align: Align,
    sortable: Bool,
    hideable: Bool,
    filter: Option(FilterKind),
  )
}

pub type Schema {
  Schema(table_id: String, columns: List(Column), default_sort: Option(Sort))
}

pub fn column_type_to_string(column_type: ColumnType) -> String {
  case column_type {
    TextType -> "text"
    NumberType -> "number"
    MoneyType -> "money"
    DateType -> "date"
    EnumType -> "enum"
    EntityType -> "entity"
    PersonType -> "person"
    ChipsType -> "chips"
    BoolType -> "bool"
  }
}

pub fn column_type_from_string(text: String) -> Result(ColumnType, Nil) {
  case text {
    "text" -> Ok(TextType)
    "number" -> Ok(NumberType)
    "money" -> Ok(MoneyType)
    "date" -> Ok(DateType)
    "enum" -> Ok(EnumType)
    "entity" -> Ok(EntityType)
    "person" -> Ok(PersonType)
    "chips" -> Ok(ChipsType)
    "bool" -> Ok(BoolType)
    _ -> Error(Nil)
  }
}

pub fn tone_to_string(tone: Tone) -> String {
  case tone {
    Neutral -> "neutral"
    Accent -> "accent"
    Positive -> "positive"
    Warning -> "warning"
    Critical -> "critical"
  }
}

pub fn tone_from_string(text: String) -> Result(Tone, Nil) {
  case text {
    "neutral" -> Ok(Neutral)
    "accent" -> Ok(Accent)
    "positive" -> Ok(Positive)
    "warning" -> Ok(Warning)
    "critical" -> Ok(Critical)
    _ -> Error(Nil)
  }
}

fn align_to_string(align: Align) -> String {
  case align {
    Start -> "start"
    NumericEnd -> "num"
  }
}

fn align_from_string(text: String) -> Align {
  case text {
    "num" -> NumericEnd
    _ -> Start
  }
}

pub fn encode_schema(schema: Schema) -> Json {
  json.object([
    #("table_id", json.string(schema.table_id)),
    #("columns", json.array(schema.columns, encode_column)),
    #("default_sort", json.nullable(schema.default_sort, sort.encode_sort)),
  ])
}

fn encode_column(column: Column) -> Json {
  json.object([
    #("key", json.string(column.key)),
    #("label", json.string(column.label)),
    #("type", json.string(column_type_to_string(column.column_type))),
    #("align", json.string(align_to_string(column.align))),
    #("sortable", json.bool(column.sortable)),
    #("hideable", json.bool(column.hideable)),
    #("filter", json.nullable(column.filter, filter.encode_filter_kind)),
  ])
}

pub fn schema_decoder() -> Decoder(Schema) {
  use table_id <- decode.field("table_id", decode.string)
  use columns <- decode.field("columns", decode.list(column_decoder()))
  use default_sort <- decode.field(
    "default_sort",
    decode.optional(sort.sort_decoder()),
  )
  decode.success(Schema(table_id:, columns:, default_sort:))
}

fn column_decoder() -> Decoder(Column) {
  use key <- decode.field("key", decode.string)
  use label <- decode.field("label", decode.string)
  use type_text <- decode.field("type", decode.string)
  use align_text <- decode.field("align", decode.string)
  use sortable <- decode.field("sortable", decode.bool)
  use hideable <- decode.field("hideable", decode.bool)
  use filter <- decode.field(
    "filter",
    decode.optional(filter.filter_kind_decoder()),
  )
  let column_type = case column_type_from_string(type_text) {
    Ok(value) -> value
    Error(Nil) -> TextType
  }
  decode.success(Column(
    key:,
    label:,
    column_type:,
    align: align_from_string(align_text),
    sortable:,
    hideable:,
    filter:,
  ))
}
