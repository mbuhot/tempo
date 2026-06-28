//// The typed value a workflow field holds. Self-describing on the wire (a `type`
//// tag beside the raw `value`) so a `DraftView` decodes without the schema in hand.
//// `parse` lifts a raw input string into the right variant for a field's type, and
//// `to_input` renders a stored value back into an input string for the client.

import gleam/dynamic/decode.{type Decoder}
import gleam/int
import gleam/json.{type Json}
import gleam/string
import gleam/time/calendar.{type Date}
import shared/money.{type Money}
import shared/wire
import shared/workflow/schema.{
  type FieldType, BoolField, DateField, EmailField, EnumField, IntField,
  MoneyField, PersonField, TextField,
}

/// A field's saved value, tagged so it round-trips independently of the schema.
pub type FieldValue {
  TextValue(String)
  IntValue(Int)
  MoneyValue(Money)
  DateValue(Date)
  BoolValue(Bool)
  PersonValue(Int)
}

fn tag(value: FieldValue) -> String {
  case value {
    TextValue(..) -> "text"
    IntValue(..) -> "int"
    MoneyValue(..) -> "money"
    DateValue(..) -> "date"
    BoolValue(..) -> "bool"
    PersonValue(..) -> "person"
  }
}

fn encode_raw(value: FieldValue) -> Json {
  case value {
    TextValue(text) -> json.string(text)
    IntValue(number) -> json.int(number)
    MoneyValue(amount) -> money.encode(amount)
    DateValue(date) -> wire.encode_date(date)
    BoolValue(flag) -> json.bool(flag)
    PersonValue(id) -> json.int(id)
  }
}

pub fn encode(value: FieldValue) -> Json {
  json.object([
    #("type", json.string(tag(value))),
    #("value", encode_raw(value)),
  ])
}

pub fn decoder() -> Decoder(FieldValue) {
  use type_text <- decode.field("type", decode.string)
  case type_text {
    "int" -> decode.at(["value"], decode.int) |> decode.map(IntValue)
    "money" -> decode.at(["value"], money.decoder()) |> decode.map(MoneyValue)
    "date" -> decode.at(["value"], wire.date_decoder()) |> decode.map(DateValue)
    "bool" -> decode.at(["value"], decode.bool) |> decode.map(BoolValue)
    "person" -> decode.at(["value"], decode.int) |> decode.map(PersonValue)
    _ -> decode.at(["value"], decode.string) |> decode.map(TextValue)
  }
}

/// Lift a raw input string into the variant a field of `kind` expects. Returns
/// `Error` when the input does not parse (the caller surfaces a format error).
pub fn parse(of kind: FieldType, raw raw: String) -> Result(FieldValue, Nil) {
  case kind {
    TextField | EmailField -> Ok(TextValue(raw))
    EnumField(..) -> Ok(TextValue(raw))
    IntField ->
      case int.parse(raw) {
        Ok(number) -> Ok(IntValue(number))
        Error(Nil) -> Error(Nil)
      }
    MoneyField ->
      case money.from_string(raw) {
        Ok(amount) -> Ok(MoneyValue(amount))
        Error(Nil) -> Error(Nil)
      }
    DateField ->
      case wire.parse_iso_date(raw) {
        Ok(date) -> Ok(DateValue(date))
        Error(Nil) -> Error(Nil)
      }
    PersonField ->
      case int.parse(raw) {
        Ok(id) -> Ok(PersonValue(id))
        Error(Nil) -> Error(Nil)
      }
    BoolField ->
      case raw {
        "true" -> Ok(BoolValue(True))
        "false" -> Ok(BoolValue(False))
        _ -> Error(Nil)
      }
  }
}

/// Render a stored value as the string an input control shows.
pub fn to_input(value: FieldValue) -> String {
  case value {
    TextValue(text) -> text
    IntValue(number) -> int.to_string(number)
    MoneyValue(amount) -> money.to_string(amount)
    DateValue(date) -> iso(date)
    PersonValue(id) -> int.to_string(id)
    BoolValue(True) -> "true"
    BoolValue(False) -> "false"
  }
}

fn iso(date: Date) -> String {
  let calendar.Date(year:, month:, day:) = date
  pad(year, 4)
  <> "-"
  <> pad(calendar.month_to_int(month), 2)
  <> "-"
  <> pad(day, 2)
}

fn pad(value: Int, width: Int) -> String {
  int.to_string(value) |> string.pad_start(to: width, with: "0")
}
