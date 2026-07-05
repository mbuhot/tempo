//// Reads for meetings: the upcoming-scheduled listing, each meeting paired with its
//// attendees. Two queries (`meetings_upcoming`, `meeting_attendees_asof`) are folded in
//// Gleam — attendee rows are grouped by `meeting_id` into a `dict`, then zipped onto
//// each meeting row — because a meeting can hold any number of attendees, which a
//// single join would fan out and duplicate the meeting columns across.

import gleam/dict.{type Dict}
import gleam/list
import gleam/option
import gleam/result
import gleam/time/calendar.{type Date}
import pog
import shared/meeting/command.{type Attendance, Optional, Required}
import shared/meeting/view.{
  type AttendeeRecord, type MeetingRecord, AttendeeRecord, MeetingRecord,
}
import tempo/server/context.{type Context}
import tempo/server/meeting/sql

/// Every scheduled meeting ending on/after `as_of`, earliest first, each with its
/// attendees and their as-of-`as_of` local UTC offsets.
pub fn upcoming(
  context: Context,
  as_of: Date,
) -> Result(List(MeetingRecord), pog.QueryError) {
  use meetings <- result.try(sql.meetings_upcoming(context.db, as_of))
  use attendees <- result.map(sql.meeting_attendees_asof(context.db, as_of))
  let attendees_by_meeting = group_attendees(attendees.rows)
  list.map(meetings.rows, fn(row) {
    meeting_row_to_record(row, attendees_by_meeting)
  })
}

fn group_attendees(
  rows: List(sql.MeetingAttendeesAsofRow),
) -> Dict(Int, List(AttendeeRecord)) {
  rows
  |> list.map(attendee_row_to_record)
  |> list.fold(dict.new(), fn(by_meeting, entry) {
    let #(meeting_id, record) = entry
    dict.upsert(by_meeting, meeting_id, fn(existing) {
      case existing {
        option.Some(records) -> list.append(records, [record])
        option.None -> [record]
      }
    })
  })
}

fn attendee_row_to_record(
  row: sql.MeetingAttendeesAsofRow,
) -> #(Int, AttendeeRecord) {
  #(
    row.meeting_id,
    AttendeeRecord(
      engineer_id: row.engineer_id,
      name: option.unwrap(row.name, ""),
      attendance: attendance_of(row.attendance),
      timezone: row.timezone,
      local_offset_minutes: row.local_offset_minutes,
    ),
  )
}

fn attendance_of(tag: String) -> Attendance {
  case tag {
    "optional" -> Optional
    _ -> Required
  }
}

fn meeting_row_to_record(
  row: sql.MeetingsUpcomingRow,
  attendees_by_meeting: Dict(Int, List(AttendeeRecord)),
) -> MeetingRecord {
  MeetingRecord(
    meeting_id: row.meeting_id,
    title: row.title,
    meeting_tz: row.meeting_tz,
    starts_at: row.starts_at,
    ends_at: row.ends_at,
    canonical_offset_minutes: row.canonical_offset_minutes,
    location: row.location,
    client_id: row.client_id,
    project_id: row.project_id,
    attendees: dict.get(attendees_by_meeting, row.meeting_id)
      |> result.unwrap([]),
  )
}
