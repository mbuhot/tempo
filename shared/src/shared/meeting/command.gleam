//// Write commands for meetings. Meetings are plain mutable rows, but writes still flow
//// through the dispatch/audit seam like every tempo command; each is tagged by `op`.

import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import gleam/option.{type Option}
import gleam/time/calendar.{type Date}
import shared/wire.{date_decoder, encode_date}

pub type Attendance {
  Required
  Optional
}

pub type MeetingCommand {
  ScheduleMeeting(
    title: String,
    timezone: String,
    date: Date,
    starts_at: String,
    duration_minutes: Int,
    location: Option(String),
    client_id: Option(Int),
    project_id: Option(Int),
    attendees: List(#(Int, Attendance)),
  )
  RescheduleMeeting(
    meeting_id: Int,
    timezone: String,
    date: Date,
    starts_at: String,
    duration_minutes: Int,
  )
  CancelMeeting(meeting_id: Int)
  AddAttendee(meeting_id: Int, engineer_id: Int, attendance: Attendance)
  RemoveAttendee(meeting_id: Int, engineer_id: Int)
}

pub fn encode_attendance(attendance: Attendance) -> Json {
  case attendance {
    Required -> json.string("required")
    Optional -> json.string("optional")
  }
}

pub fn attendance_decoder() -> Decoder(Attendance) {
  use raw <- decode.then(decode.string)
  case raw {
    "optional" -> decode.success(Optional)
    _ -> decode.success(Required)
  }
}

fn encode_attendee(pair: #(Int, Attendance)) -> Json {
  let #(engineer_id, attendance) = pair
  json.object([
    #("engineer_id", json.int(engineer_id)),
    #("attendance", encode_attendance(attendance)),
  ])
}

fn attendee_decoder() -> Decoder(#(Int, Attendance)) {
  use engineer_id <- decode.field("engineer_id", decode.int)
  use attendance <- decode.field("attendance", attendance_decoder())
  decode.success(#(engineer_id, attendance))
}

pub fn encode(command: MeetingCommand) -> Json {
  case command {
    ScheduleMeeting(
      title:,
      timezone:,
      date:,
      starts_at:,
      duration_minutes:,
      location:,
      client_id:,
      project_id:,
      attendees:,
    ) ->
      json.object([
        #("op", json.string("schedule_meeting")),
        #("title", json.string(title)),
        #("timezone", json.string(timezone)),
        #("date", encode_date(date)),
        #("starts_at", json.string(starts_at)),
        #("duration_minutes", json.int(duration_minutes)),
        #("location", json.nullable(location, json.string)),
        #("client_id", json.nullable(client_id, json.int)),
        #("project_id", json.nullable(project_id, json.int)),
        #("attendees", json.array(attendees, encode_attendee)),
      ])
    RescheduleMeeting(
      meeting_id:,
      timezone:,
      date:,
      starts_at:,
      duration_minutes:,
    ) ->
      json.object([
        #("op", json.string("reschedule_meeting")),
        #("meeting_id", json.int(meeting_id)),
        #("timezone", json.string(timezone)),
        #("date", encode_date(date)),
        #("starts_at", json.string(starts_at)),
        #("duration_minutes", json.int(duration_minutes)),
      ])
    CancelMeeting(meeting_id:) ->
      json.object([
        #("op", json.string("cancel_meeting")),
        #("meeting_id", json.int(meeting_id)),
      ])
    AddAttendee(meeting_id:, engineer_id:, attendance:) ->
      json.object([
        #("op", json.string("add_attendee")),
        #("meeting_id", json.int(meeting_id)),
        #("engineer_id", json.int(engineer_id)),
        #("attendance", encode_attendance(attendance)),
      ])
    RemoveAttendee(meeting_id:, engineer_id:) ->
      json.object([
        #("op", json.string("remove_attendee")),
        #("meeting_id", json.int(meeting_id)),
        #("engineer_id", json.int(engineer_id)),
      ])
  }
}

pub fn decoder(op: String) -> Result(Decoder(MeetingCommand), Nil) {
  case op {
    "schedule_meeting" ->
      Ok({
        use title <- decode.field("title", decode.string)
        use timezone <- decode.field("timezone", decode.string)
        use date <- decode.field("date", date_decoder())
        use starts_at <- decode.field("starts_at", decode.string)
        use duration_minutes <- decode.field("duration_minutes", decode.int)
        use location <- decode.field("location", decode.optional(decode.string))
        use client_id <- decode.field("client_id", decode.optional(decode.int))
        use project_id <- decode.field(
          "project_id",
          decode.optional(decode.int),
        )
        use attendees <- decode.field(
          "attendees",
          decode.list(attendee_decoder()),
        )
        decode.success(ScheduleMeeting(
          title:,
          timezone:,
          date:,
          starts_at:,
          duration_minutes:,
          location:,
          client_id:,
          project_id:,
          attendees:,
        ))
      })
    "reschedule_meeting" ->
      Ok({
        use meeting_id <- decode.field("meeting_id", decode.int)
        use timezone <- decode.field("timezone", decode.string)
        use date <- decode.field("date", date_decoder())
        use starts_at <- decode.field("starts_at", decode.string)
        use duration_minutes <- decode.field("duration_minutes", decode.int)
        decode.success(RescheduleMeeting(
          meeting_id:,
          timezone:,
          date:,
          starts_at:,
          duration_minutes:,
        ))
      })
    "cancel_meeting" ->
      Ok({
        use meeting_id <- decode.field("meeting_id", decode.int)
        decode.success(CancelMeeting(meeting_id:))
      })
    "add_attendee" ->
      Ok({
        use meeting_id <- decode.field("meeting_id", decode.int)
        use engineer_id <- decode.field("engineer_id", decode.int)
        use attendance <- decode.field("attendance", attendance_decoder())
        decode.success(AddAttendee(meeting_id:, engineer_id:, attendance:))
      })
    "remove_attendee" ->
      Ok({
        use meeting_id <- decode.field("meeting_id", decode.int)
        use engineer_id <- decode.field("engineer_id", decode.int)
        decode.success(RemoveAttendee(meeting_id:, engineer_id:))
      })
    _ -> Error(Nil)
  }
}
