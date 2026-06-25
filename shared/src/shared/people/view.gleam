//// The people-list read models and their JSON codecs: an engineer's folded
//// `RosterStatus`, one `PersonRow`, and the `PeopleList` for a date. Pure Gleam,
//// no target-specific deps, so they round-trip on both ends of the JSON-over-HTTP
//// boundary. Dates serialise as ISO-8601 "YYYY-MM-DD" strings; money/fraction
//// fields decode leniently.

import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import gleam/option.{type Option}
import gleam/time/calendar.{type Date}
import shared/pagination
import shared/wire

/// An engineer's roster situation collapsed to a single cell for the people list
/// (distinct from `Engagement`, which is one row per project). Several allocations
/// fold into one `RosterOnProjects` carrying the project titles; a covering leave
/// fact wins as `RosterOnLeave`; an employed engineer with neither is
/// `RosterUnassigned`. Band is NOT a wire field — it is a client-side label
/// derived from `level`.
pub type RosterStatus {
  RosterOnLeave(kind: String)
  RosterOnProjects(projects: List(String))
  RosterUnassigned
}

/// One row of the people list (`GET /api/people?as_of=`): an employed engineer
/// with their `level`, roster `status`, summed `allocated_fraction` as-of (0.0 on
/// bench/leave), `annual_balance` (annual leave days), and the level's resolved
/// `day_rate` (charge rate). Present for ALL employed engineers, not just
/// allocated ones. Band is derived client-side from `level`.
pub type PersonRow {
  PersonRow(
    engineer_id: Int,
    name: String,
    email: String,
    level: Int,
    status: RosterStatus,
    allocated_fraction: Float,
    annual_balance: Float,
    day_rate: Float,
  )
}

/// The people list for a single date: every employed engineer's `PersonRow`
/// as-of the `date` (mirrors `BoardSnapshot`'s date + rows shape), plus the opaque
/// `next_cursor` for the following keyset page (`None` on the last page; issue
/// #12). The item shape is unchanged — `next_cursor` is purely additive.
pub type PeopleList {
  PeopleList(
    date: Date,
    people: List(PersonRow),
    next_cursor: Option(String),
  )
}

/// Encode a `RosterStatus` as a tagged JSON object keyed by `status`.
pub fn encode_roster_status(status: RosterStatus) -> Json {
  case status {
    RosterOnLeave(kind:) ->
      json.object([
        #("status", json.string("on_leave")),
        #("kind", json.string(kind)),
      ])
    RosterOnProjects(projects:) ->
      json.object([
        #("status", json.string("on_projects")),
        #("projects", json.array(projects, json.string)),
      ])
    RosterUnassigned -> json.object([#("status", json.string("unassigned"))])
  }
}

/// Decode a `RosterStatus` from its tagged JSON object.
pub fn roster_status_decoder() -> Decoder(RosterStatus) {
  use status <- decode.field("status", decode.string)
  case status {
    "on_leave" -> {
      use kind <- decode.field("kind", decode.string)
      decode.success(RosterOnLeave(kind:))
    }
    "on_projects" -> {
      use projects <- decode.field("projects", decode.list(decode.string))
      decode.success(RosterOnProjects(projects:))
    }
    "unassigned" -> decode.success(RosterUnassigned)
    _ -> decode.failure(RosterUnassigned, "RosterStatus")
  }
}

/// Encode a `PersonRow` (one people-list row) as a JSON object.
pub fn encode_person_row(person: PersonRow) -> Json {
  let PersonRow(
    engineer_id:,
    name:,
    email:,
    level:,
    status:,
    allocated_fraction:,
    annual_balance:,
    day_rate:,
  ) = person
  json.object([
    #("engineer_id", json.int(engineer_id)),
    #("name", json.string(name)),
    #("email", json.string(email)),
    #("level", json.int(level)),
    #("status", encode_roster_status(status)),
    #("allocated_fraction", json.float(allocated_fraction)),
    #("annual_balance", json.float(annual_balance)),
    #("day_rate", json.float(day_rate)),
  ])
}

/// Decode a `PersonRow` from a JSON object.
pub fn person_row_decoder() -> Decoder(PersonRow) {
  use engineer_id <- decode.field("engineer_id", decode.int)
  use name <- decode.field("name", decode.string)
  use email <- decode.field("email", decode.string)
  use level <- decode.field("level", decode.int)
  use status <- decode.field("status", roster_status_decoder())
  use allocated_fraction <- decode.field(
    "allocated_fraction",
    wire.lenient_float_decoder(),
  )
  use annual_balance <- decode.field(
    "annual_balance",
    wire.lenient_float_decoder(),
  )
  use day_rate <- decode.field("day_rate", wire.lenient_float_decoder())
  decode.success(PersonRow(
    engineer_id:,
    name:,
    email:,
    level:,
    status:,
    allocated_fraction:,
    annual_balance:,
    day_rate:,
  ))
}

/// Encode a `PeopleList` (the people list for a date) to JSON.
pub fn encode_people_list(list: PeopleList) -> Json {
  let PeopleList(date:, people:, next_cursor:) = list
  json.object([
    #("date", wire.encode_date(date)),
    #("people", json.array(people, encode_person_row)),
    #("next_cursor", pagination.encode_next_cursor(next_cursor)),
  ])
}

/// Decode a `PeopleList` from JSON.
pub fn people_list_decoder() -> Decoder(PeopleList) {
  use date <- decode.field("date", wire.date_decoder())
  use people <- decode.field("people", decode.list(person_row_decoder()))
  use next_cursor <- decode.field(
    "next_cursor",
    pagination.next_cursor_decoder(),
  )
  decode.success(PeopleList(date:, people:, next_cursor:))
}
