//// The read model for upcoming meetings: a `MeetingRecord` (the meeting plus its
//// attendees) and each attendee's `AttendeeRecord`. Times cross the wire as ISO-8601
//// UTC instants; the canonical and per-attendee UTC offsets (minutes east) let the
//// client render every local time without shipping a timezone library.

import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import gleam/option.{type Option}
import shared/meeting/command.{
  type Attendance, attendance_decoder, encode_attendance,
}

pub type AttendeeRecord {
  AttendeeRecord(
    engineer_id: Int,
    name: String,
    attendance: Attendance,
    timezone: Option(String),
    local_offset_minutes: Option(Int),
  )
}

pub type MeetingRecord {
  MeetingRecord(
    meeting_id: Int,
    title: String,
    meeting_tz: String,
    starts_at: String,
    ends_at: String,
    canonical_offset_minutes: Int,
    location: Option(String),
    client_id: Option(Int),
    project_id: Option(Int),
    attendees: List(AttendeeRecord),
  )
}

pub fn encode_attendee_record(record: AttendeeRecord) -> Json {
  let AttendeeRecord(
    engineer_id:,
    name:,
    attendance:,
    timezone:,
    local_offset_minutes:,
  ) = record
  json.object([
    #("engineer_id", json.int(engineer_id)),
    #("name", json.string(name)),
    #("attendance", encode_attendance(attendance)),
    #("timezone", json.nullable(timezone, json.string)),
    #("local_offset_minutes", json.nullable(local_offset_minutes, json.int)),
  ])
}

pub fn attendee_record_decoder() -> Decoder(AttendeeRecord) {
  use engineer_id <- decode.field("engineer_id", decode.int)
  use name <- decode.field("name", decode.string)
  use attendance <- decode.field("attendance", attendance_decoder())
  use timezone <- decode.field("timezone", decode.optional(decode.string))
  use local_offset_minutes <- decode.field(
    "local_offset_minutes",
    decode.optional(decode.int),
  )
  decode.success(AttendeeRecord(
    engineer_id:,
    name:,
    attendance:,
    timezone:,
    local_offset_minutes:,
  ))
}

pub fn encode_meeting_record(record: MeetingRecord) -> Json {
  let MeetingRecord(
    meeting_id:,
    title:,
    meeting_tz:,
    starts_at:,
    ends_at:,
    canonical_offset_minutes:,
    location:,
    client_id:,
    project_id:,
    attendees:,
  ) = record
  json.object([
    #("meeting_id", json.int(meeting_id)),
    #("title", json.string(title)),
    #("meeting_tz", json.string(meeting_tz)),
    #("starts_at", json.string(starts_at)),
    #("ends_at", json.string(ends_at)),
    #("canonical_offset_minutes", json.int(canonical_offset_minutes)),
    #("location", json.nullable(location, json.string)),
    #("client_id", json.nullable(client_id, json.int)),
    #("project_id", json.nullable(project_id, json.int)),
    #("attendees", json.array(attendees, encode_attendee_record)),
  ])
}

pub type SlotAttendee {
  SlotAttendee(
    engineer_id: Int,
    name: String,
    attendance: Attendance,
    timezone: Option(String),
    offset_minutes: Option(Int),
  )
}

pub type CandidateSlot {
  CandidateSlot(
    starts_at: String,
    ends_at: String,
    attendees: List(SlotAttendee),
  )
}

pub fn encode_slot_attendee(attendee: SlotAttendee) -> Json {
  let SlotAttendee(engineer_id:, name:, attendance:, timezone:, offset_minutes:) =
    attendee
  json.object([
    #("engineer_id", json.int(engineer_id)),
    #("name", json.string(name)),
    #("attendance", encode_attendance(attendance)),
    #("timezone", json.nullable(timezone, json.string)),
    #("offset_minutes", json.nullable(offset_minutes, json.int)),
  ])
}

pub fn slot_attendee_decoder() -> Decoder(SlotAttendee) {
  use engineer_id <- decode.field("engineer_id", decode.int)
  use name <- decode.field("name", decode.string)
  use attendance <- decode.field("attendance", attendance_decoder())
  use timezone <- decode.field("timezone", decode.optional(decode.string))
  use offset_minutes <- decode.field(
    "offset_minutes",
    decode.optional(decode.int),
  )
  decode.success(SlotAttendee(
    engineer_id:,
    name:,
    attendance:,
    timezone:,
    offset_minutes:,
  ))
}

pub fn encode_candidate_slot(slot: CandidateSlot) -> Json {
  let CandidateSlot(starts_at:, ends_at:, attendees:) = slot
  json.object([
    #("starts_at", json.string(starts_at)),
    #("ends_at", json.string(ends_at)),
    #("attendees", json.array(attendees, encode_slot_attendee)),
  ])
}

pub fn candidate_slot_decoder() -> Decoder(CandidateSlot) {
  use starts_at <- decode.field("starts_at", decode.string)
  use ends_at <- decode.field("ends_at", decode.string)
  use attendees <- decode.field(
    "attendees",
    decode.list(slot_attendee_decoder()),
  )
  decode.success(CandidateSlot(starts_at:, ends_at:, attendees:))
}

pub fn meeting_record_decoder() -> Decoder(MeetingRecord) {
  use meeting_id <- decode.field("meeting_id", decode.int)
  use title <- decode.field("title", decode.string)
  use meeting_tz <- decode.field("meeting_tz", decode.string)
  use starts_at <- decode.field("starts_at", decode.string)
  use ends_at <- decode.field("ends_at", decode.string)
  use canonical_offset_minutes <- decode.field(
    "canonical_offset_minutes",
    decode.int,
  )
  use location <- decode.field("location", decode.optional(decode.string))
  use client_id <- decode.field("client_id", decode.optional(decode.int))
  use project_id <- decode.field("project_id", decode.optional(decode.int))
  use attendees <- decode.field(
    "attendees",
    decode.list(attendee_record_decoder()),
  )
  decode.success(MeetingRecord(
    meeting_id:,
    title:,
    meeting_tz:,
    starts_at:,
    ends_at:,
    canonical_offset_minutes:,
    location:,
    client_id:,
    project_id:,
    attendees:,
  ))
}
