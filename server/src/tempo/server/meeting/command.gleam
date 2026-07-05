//// Write handler for meetings. schedule validates the TZID and mints a meeting id, then
//// records its subject, an open booking, and its attendees as facts; reschedule and
//// cancel each record a booking transition (the repository closes and, for reschedule,
//// re-opens the booking fact).

import gleam/int
import gleam/list
import gleam/option.{type Option}
import gleam/result
import gleam/time/calendar.{type Date}
import pog
import shared/command as gateway
import shared/meeting/command.{
  type Attendance, type MeetingCommand, AddAttendee, CancelMeeting, Optional,
  RemoveAttendee, Required, RescheduleMeeting, ScheduleMeeting,
}
import tempo/server/fact.{
  type Recorded, MeetingAttendeeAdded, MeetingAttendeeRemoved,
  MeetingBookingOpened, MeetingCancelled, MeetingId, MeetingRescheduled,
  MeetingSubjectSet, Recorded,
}
import tempo/server/meeting/sql as meeting_sql
import tempo/server/operation.{type OperationError, Event}
import tempo/server/repository

/// Route a meeting command to its operation, returning the audit entry and the facts
/// it records. Exhaustive over `MeetingCommand`.
pub fn route(
  conn: pog.Connection,
  command: MeetingCommand,
) -> Result(Recorded, OperationError) {
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
      schedule(
        conn,
        command,
        title:,
        timezone:,
        date:,
        starts_at:,
        duration_minutes:,
        location:,
        client_id:,
        project_id:,
        attendees:,
      )
    RescheduleMeeting(
      meeting_id:,
      timezone:,
      date:,
      starts_at:,
      duration_minutes:,
    ) ->
      reschedule(
        conn,
        command,
        meeting_id:,
        timezone:,
        date:,
        starts_at:,
        duration_minutes:,
      )
    CancelMeeting(meeting_id:) -> Ok(cancel(command, meeting_id:))
    AddAttendee(meeting_id:, engineer_id:, attendance:) ->
      Ok(add_attendee(command, meeting_id:, engineer_id:, attendance:))
    RemoveAttendee(meeting_id:, engineer_id:) ->
      Ok(remove_attendee(command, meeting_id:, engineer_id:))
  }
}

fn attendance_tag(attendance: Attendance) -> String {
  case attendance {
    Required -> "required"
    Optional -> "optional"
  }
}

/// Mint the meeting id and record its subject, an open booking, and one
/// `MeetingAttendeeAdded` per attendee, once its IANA TZID is confirmed against
/// `pg_timezone_names`.
fn schedule(
  conn: pog.Connection,
  command: MeetingCommand,
  title title: String,
  timezone timezone: String,
  date date: Date,
  starts_at starts_at: String,
  duration_minutes duration_minutes: Int,
  location location: Option(String),
  client_id client_id: Option(Int),
  project_id project_id: Option(Int),
  attendees attendees: List(#(Int, Attendance)),
) -> Result(Recorded, OperationError) {
  use valid <- operation.try(meeting_sql.timezone_valid(conn, timezone))
  let assert [check] = valid.rows
  case check.valid {
    False -> Error(operation.InvalidValue)
    True -> {
      use meeting_id <- result.try(repository.create_meeting(conn))
      let MeetingId(id) = meeting_id
      let subject =
        MeetingSubjectSet(
          meeting_id: MeetingId(id),
          title:,
          client_id:,
          project_id:,
        )
      let booking =
        MeetingBookingOpened(
          meeting_id: MeetingId(id),
          date:,
          starts_at:,
          duration_minutes:,
          timezone:,
          location:,
        )
      let attendee_facts =
        list.map(attendees, fn(pair) {
          let #(engineer_id, attendance) = pair
          MeetingAttendeeAdded(
            meeting_id: MeetingId(id),
            engineer_id:,
            attendance: attendance_tag(attendance),
          )
        })
      Ok(
        Recorded(
          entry: Event(
            operation: "schedule_meeting",
            summary: "Scheduled \""
              <> title
              <> "\" on "
              <> operation.iso(date)
              <> " "
              <> starts_at
              <> " ("
              <> timezone
              <> ")",
            payload: gateway.encode_command(gateway.MeetingCommand(command)),
          ),
          facts: [subject, booking, ..attendee_facts],
        ),
      )
    }
  }
}

/// Move a meeting in place, once its IANA TZID is confirmed against
/// `pg_timezone_names`. `repository.write` gates a missing meeting via
/// `NoSuchVersion`.
fn reschedule(
  conn: pog.Connection,
  command: MeetingCommand,
  meeting_id meeting_id: Int,
  timezone timezone: String,
  date date: Date,
  starts_at starts_at: String,
  duration_minutes duration_minutes: Int,
) -> Result(Recorded, OperationError) {
  use valid <- operation.try(meeting_sql.timezone_valid(conn, timezone))
  let assert [check] = valid.rows
  case check.valid {
    False -> Error(operation.InvalidValue)
    True ->
      Ok(
        Recorded(
          entry: Event(
            operation: "reschedule_meeting",
            summary: "Rescheduled meeting "
              <> int.to_string(meeting_id)
              <> " to "
              <> operation.iso(date)
              <> " "
              <> starts_at
              <> " ("
              <> timezone
              <> ")",
            payload: gateway.encode_command(gateway.MeetingCommand(command)),
          ),
          facts: [
            MeetingRescheduled(
              meeting_id: MeetingId(meeting_id),
              date:,
              starts_at:,
              duration_minutes:,
              timezone:,
            ),
          ],
        ),
      )
  }
}

/// Mark a meeting cancelled. `repository.write` gates a missing meeting via
/// `NoSuchVersion`.
fn cancel(command: MeetingCommand, meeting_id meeting_id: Int) -> Recorded {
  Recorded(
    entry: Event(
      operation: "cancel_meeting",
      summary: "Cancelled meeting " <> int.to_string(meeting_id),
      payload: gateway.encode_command(gateway.MeetingCommand(command)),
    ),
    facts: [MeetingCancelled(meeting_id: MeetingId(meeting_id))],
  )
}

/// Add or re-mark an attendee.
fn add_attendee(
  command: MeetingCommand,
  meeting_id meeting_id: Int,
  engineer_id engineer_id: Int,
  attendance attendance: Attendance,
) -> Recorded {
  Recorded(
    entry: Event(
      operation: "add_attendee",
      summary: "Added engineer "
        <> int.to_string(engineer_id)
        <> " to meeting "
        <> int.to_string(meeting_id),
      payload: gateway.encode_command(gateway.MeetingCommand(command)),
    ),
    facts: [
      MeetingAttendeeAdded(
        meeting_id: MeetingId(meeting_id),
        engineer_id:,
        attendance: attendance_tag(attendance),
      ),
    ],
  )
}

/// Drop an attendee.
fn remove_attendee(
  command: MeetingCommand,
  meeting_id meeting_id: Int,
  engineer_id engineer_id: Int,
) -> Recorded {
  Recorded(
    entry: Event(
      operation: "remove_attendee",
      summary: "Removed engineer "
        <> int.to_string(engineer_id)
        <> " from meeting "
        <> int.to_string(meeting_id),
      payload: gateway.encode_command(gateway.MeetingCommand(command)),
    ),
    facts: [
      MeetingAttendeeRemoved(meeting_id: MeetingId(meeting_id), engineer_id:),
    ],
  )
}
