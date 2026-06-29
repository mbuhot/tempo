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
  type ColumnType, type Tone, ActionsType, BoolType, ChipsType, DateType,
  EntityType, EnumType, MoneyType, Neutral, NumberType, PercentType, PersonType,
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
  EntityCell(label: String, sub: Option(String), swatch: Swatch)
  PersonCell(name: String, sub: Option(String), initials: String, category: Int)
  ChipsCell(List(Chip))
  BoolCell(Bool)
  ActionsCell(List(Action))
}

/// The value a swatch's colour is derived from. The server sends this source; the
/// client owns the mapping to a CSS token — `Category` bucketing to the `--cat-N`
/// ramp, `Level` indexing the `--lvl-N` seniority ramp, and `Placeholder` the
/// no-value-yet marker the client renders in its neutral border token.
pub type Swatch {
  Category(Int)
  Level(Int)
  Placeholder
}

pub type Chip {
  Chip(label: String, initials: Option(String))
}

/// A server-advertised per-row action: its `id` is the op the host page maps it
/// to, its `label` the button text. The server only includes the actions the
/// actor may perform on that row, so availability is decided server-side.
pub type Action {
  Action(id: String, label: String)
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
    EntityCell(label:, sub:, swatch:) ->
      json.object([
        #("label", json.string(label)),
        #("sub", json.nullable(sub, json.string)),
        #("swatch", encode_swatch(swatch)),
      ])
    PersonCell(name:, sub:, initials:, category:) ->
      json.object([
        #("name", json.string(name)),
        #("sub", json.nullable(sub, json.string)),
        #("initials", json.string(initials)),
        #("category", json.int(category)),
      ])
    ChipsCell(chips) -> json.array(chips, encode_chip)
    BoolCell(value) -> json.bool(value)
    ActionsCell(actions) -> json.array(actions, encode_action)
  }
}

fn encode_action(action: Action) -> Json {
  json.object([
    #("id", json.string(action.id)),
    #("label", json.string(action.label)),
  ])
}

fn encode_chip(chip: Chip) -> Json {
  json.object([
    #("label", json.string(chip.label)),
    #("initials", json.nullable(chip.initials, json.string)),
  ])
}

fn encode_swatch(swatch: Swatch) -> Json {
  case swatch {
    Category(id) ->
      json.object([#("kind", json.string("category")), #("value", json.int(id))])
    Level(level) ->
      json.object([#("kind", json.string("level")), #("value", json.int(level))])
    Placeholder -> json.object([#("kind", json.string("placeholder"))])
  }
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
    ActionsType -> decode.map(decode.list(action_decoder()), ActionsCell)
  }
}

fn action_decoder() -> Decoder(Action) {
  use id <- decode.field("id", decode.string)
  use label <- decode.field("label", decode.string)
  decode.success(Action(id:, label:))
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
  use swatch <- decode.field("swatch", swatch_decoder())
  decode.success(EntityCell(label:, sub:, swatch:))
}

fn person_decoder() -> Decoder(Cell) {
  use name <- decode.field("name", decode.string)
  use sub <- decode.field("sub", decode.optional(decode.string))
  use initials <- decode.field("initials", decode.string)
  use category <- decode.field("category", decode.int)
  decode.success(PersonCell(name:, sub:, initials:, category:))
}

fn chip_decoder() -> Decoder(Chip) {
  use label <- decode.field("label", decode.string)
  use initials <- decode.field("initials", decode.optional(decode.string))
  decode.success(Chip(label:, initials:))
}

fn swatch_decoder() -> Decoder(Swatch) {
  use kind <- decode.field("kind", decode.string)
  case kind {
    "placeholder" -> decode.success(Placeholder)
    "level" -> {
      use value <- decode.field("value", decode.int)
      decode.success(Level(value))
    }
    _ -> {
      use value <- decode.field("value", decode.int)
      decode.success(Category(value))
    }
  }
}
