//// A table cell's value. Cells travel UNTAGGED on the wire — the column's
//// `ColumnType` directs `cell_decoder` to the right variant, so the type lives once
//// on the column. The `Cell` union mirrors `ColumnType`; both `cell_decoder` (on
//// `ColumnType`) and `encode_cell` (on `Cell`) are exhaustive, keeping the two in
//// lockstep at build time.

import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import gleam/option.{type Option}
import gleam/time/calendar.{type Date}
import shared/money.{type Money}
import shared/table/column.{
  type ColumnType, type Tone, BoolType, ChipsType, DateType, EntityType,
  EnumType, MoneyType, Neutral, NumberType, PercentType, PersonType,
  SignedMoneyType, TextType,
}
import shared/wire

pub type Cell {
  TextCell(String)
  NumberCell(Float)
  PercentCell(Float)
  MoneyCell(Money)
  SignedMoneyCell(amount: Money, tone: Tone)
  DateCell(Date)
  EnumCell(label: String, tone: Tone)
  EntityCell(label: String, sub: Option(String), color: String)
  PersonCell(name: String, sub: Option(String), initials: String, color: String)
  ChipsCell(List(Chip))
  BoolCell(Bool)
}

pub type Chip {
  Chip(label: String, initials: Option(String), color: Option(String))
}

pub fn encode_cell(cell: Cell) -> Json {
  case cell {
    TextCell(value) -> json.string(value)
    NumberCell(value) -> json.float(value)
    PercentCell(value) -> json.float(value)
    MoneyCell(value) -> money.encode(value)
    SignedMoneyCell(amount:, tone:) ->
      json.object([
        #("amount", money.encode(amount)),
        #("tone", json.string(column.tone_to_string(tone))),
      ])
    DateCell(value) -> wire.encode_date(value)
    EnumCell(label:, tone:) ->
      json.object([
        #("label", json.string(label)),
        #("tone", json.string(column.tone_to_string(tone))),
      ])
    EntityCell(label:, sub:, color:) ->
      json.object([
        #("label", json.string(label)),
        #("sub", json.nullable(sub, json.string)),
        #("color", json.string(color)),
      ])
    PersonCell(name:, sub:, initials:, color:) ->
      json.object([
        #("name", json.string(name)),
        #("sub", json.nullable(sub, json.string)),
        #("initials", json.string(initials)),
        #("color", json.string(color)),
      ])
    ChipsCell(chips) -> json.array(chips, encode_chip)
    BoolCell(value) -> json.bool(value)
  }
}

fn encode_chip(chip: Chip) -> Json {
  json.object([
    #("label", json.string(chip.label)),
    #("initials", json.nullable(chip.initials, json.string)),
    #("color", json.nullable(chip.color, json.string)),
  ])
}

pub fn cell_decoder(of column_type: ColumnType) -> Decoder(Cell) {
  case column_type {
    TextType -> decode.map(decode.string, TextCell)
    NumberType -> decode.map(decode.float, NumberCell)
    PercentType -> decode.map(decode.float, PercentCell)
    MoneyType -> decode.map(money.decoder(), MoneyCell)
    SignedMoneyType -> signed_money_decoder()
    DateType -> decode.map(wire.date_decoder(), DateCell)
    BoolType -> decode.map(decode.bool, BoolCell)
    EnumType -> enum_decoder()
    EntityType -> entity_decoder()
    PersonType -> person_decoder()
    ChipsType -> decode.map(decode.list(chip_decoder()), ChipsCell)
  }
}

fn enum_decoder() -> Decoder(Cell) {
  use label <- decode.field("label", decode.string)
  use tone_text <- decode.field("tone", decode.string)
  let tone = case column.tone_from_string(tone_text) {
    Ok(value) -> value
    Error(Nil) -> Neutral
  }
  decode.success(EnumCell(label:, tone:))
}

fn signed_money_decoder() -> Decoder(Cell) {
  use amount <- decode.field("amount", money.decoder())
  use tone_text <- decode.field("tone", decode.string)
  let tone = case column.tone_from_string(tone_text) {
    Ok(value) -> value
    Error(Nil) -> Neutral
  }
  decode.success(SignedMoneyCell(amount:, tone:))
}

fn entity_decoder() -> Decoder(Cell) {
  use label <- decode.field("label", decode.string)
  use sub <- decode.field("sub", decode.optional(decode.string))
  use color <- decode.field("color", decode.string)
  decode.success(EntityCell(label:, sub:, color:))
}

fn person_decoder() -> Decoder(Cell) {
  use name <- decode.field("name", decode.string)
  use sub <- decode.field("sub", decode.optional(decode.string))
  use initials <- decode.field("initials", decode.string)
  use color <- decode.field("color", decode.string)
  decode.success(PersonCell(name:, sub:, initials:, color:))
}

fn chip_decoder() -> Decoder(Chip) {
  use label <- decode.field("label", decode.string)
  use initials <- decode.field("initials", decode.optional(decode.string))
  use color <- decode.field("color", decode.optional(decode.string))
  decode.success(Chip(label:, initials:, color:))
}
