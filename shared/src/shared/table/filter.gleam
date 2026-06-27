//// The filter a column offers, advertised by the server in the schema. The kind is
//// independent of the column's data-type: the server decides what it can filter.
//// `SelectFilter` carries server-supplied options, so data-driven option lists
//// (clients, projects, engineers) ship live.

import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}

pub type FilterKind {
  TextFilter
  SelectFilter(options: List(FilterOption), multi: Bool)
  NumberRangeFilter
  DateRangeFilter
  BoolFilter
}

pub type FilterOption {
  FilterOption(value: String, label: String)
}

pub fn encode_filter_kind(kind: FilterKind) -> Json {
  case kind {
    TextFilter -> json.object([#("kind", json.string("text"))])
    SelectFilter(options:, multi:) ->
      json.object([
        #("kind", json.string("select")),
        #("multi", json.bool(multi)),
        #("options", json.array(options, encode_option)),
      ])
    NumberRangeFilter -> json.object([#("kind", json.string("number_range"))])
    DateRangeFilter -> json.object([#("kind", json.string("date_range"))])
    BoolFilter -> json.object([#("kind", json.string("bool"))])
  }
}

fn encode_option(option: FilterOption) -> Json {
  json.object([
    #("value", json.string(option.value)),
    #("label", json.string(option.label)),
  ])
}

pub fn filter_kind_decoder() -> Decoder(FilterKind) {
  use kind <- decode.field("kind", decode.string)
  case kind {
    "text" -> decode.success(TextFilter)
    "number_range" -> decode.success(NumberRangeFilter)
    "date_range" -> decode.success(DateRangeFilter)
    "bool" -> decode.success(BoolFilter)
    "select" -> {
      use multi <- decode.field("multi", decode.bool)
      use options <- decode.field("options", decode.list(option_decoder()))
      decode.success(SelectFilter(options:, multi:))
    }
    _ -> decode.failure(TextFilter, "FilterKind")
  }
}

fn option_decoder() -> Decoder(FilterOption) {
  use value <- decode.field("value", decode.string)
  use label <- decode.field("label", decode.string)
  decode.success(FilterOption(value:, label:))
}
