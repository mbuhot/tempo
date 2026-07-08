//// Reads for meetings: the upcoming-scheduled listing, each meeting paired with its
//// attendees, and the cross-timezone find-a-time slot finder. Two queries
//// (`meetings_upcoming`, `meeting_attendees_asof`) are folded in Gleam — attendee rows
//// are grouped by `meeting_id` into a `dict`, then zipped onto each meeting row —
//// because a meeting can hold any number of attendees, which a single join would fan
//// out and duplicate the meeting columns across. `find_time` folds a single query's
//// rows instead: `find_a_time.sql` already orders by `(starts_at, ends_at)`, so
//// consecutive rows sharing a slot are adjacent and a linear fold groups them without
//// a dict.

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option
import gleam/result
import gleam/string
import gleam/time/calendar.{type Date}
import pog
import shared/meeting/command.{type Attendance, Optional, Required}
import shared/meeting/view.{
  type AttendeeRecord, type CandidateSlot, type MeetingRecord, type SlotAttendee,
  AttendeeRecord, CandidateSlot, MeetingRecord, SlotAttendee,
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
        option.Some(records) -> [record, ..records]
        option.None -> [record]
      }
    })
  })
  |> dict.map_values(fn(_, records) { list.reverse(records) })
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

/// Why `find_time` declined to run the finder: an unknown `timezone`, or the
/// database rejected a query.
pub type FindTimeError {
  UnknownTimezone
  FindTimeQueryFailed(error: pog.QueryError)
}

/// Every window inside `[from, to]` (dates in `timezone`, the viewer's zone) at
/// least `duration_minutes` long during which every `required` engineer is free
/// (their scheduled meetings, focus blocks, leave, and holidays all clear, and they
/// have a location on that day), earliest first. `optional` attendees ride along on
/// every returned slot with their offsets but never narrow the windows. `exclude`
/// (0 = none) vacates a meeting's own booking from the busy set, so rescheduling it
/// can offer its current slot back. Rejects an unrecognised `timezone` before
/// running the finder query.
pub fn find_time(
  context: Context,
  from: Date,
  to: Date,
  timezone: String,
  duration_minutes: Int,
  required: List(Int),
  optional: List(Int),
  exclude: Int,
) -> Result(List(CandidateSlot), FindTimeError) {
  use valid <- result.try(
    sql.timezone_valid(context.db, timezone)
    |> result.map_error(FindTimeQueryFailed),
  )
  let assert [check] = valid.rows
  case check.valid {
    False -> Error(UnknownTimezone)
    True -> {
      use rows <- result.map(
        sql.find_a_time(
          context.db,
          from,
          to,
          timezone,
          duration_minutes,
          ids_to_text(required),
          ids_to_text(optional),
          exclude,
        )
        |> result.map_error(FindTimeQueryFailed),
      )
      fold_into_slots(rows.rows)
    }
  }
}

fn ids_to_text(ids: List(Int)) -> String {
  ids
  |> list.map(int.to_string)
  |> string.join(",")
}

fn fold_into_slots(rows: List(sql.FindATimeRow)) -> List(CandidateSlot) {
  rows
  |> list.fold([], accumulate_slot)
  |> list.reverse
  |> list.map(finish_slot)
}

fn accumulate_slot(
  acc: List(CandidateSlot),
  row: sql.FindATimeRow,
) -> List(CandidateSlot) {
  case acc {
    [CandidateSlot(starts_at:, ends_at:, attendees:), ..rest]
      if starts_at == row.starts_at && ends_at == row.ends_at
    -> [
      CandidateSlot(starts_at:, ends_at:, attendees: [
        row_to_slot_attendee(row),
        ..attendees
      ]),
      ..rest
    ]
    _ -> [
      CandidateSlot(starts_at: row.starts_at, ends_at: row.ends_at, attendees: [
        row_to_slot_attendee(row),
      ]),
      ..acc
    ]
  }
}

fn finish_slot(slot: CandidateSlot) -> CandidateSlot {
  CandidateSlot(..slot, attendees: list.reverse(slot.attendees))
}

fn row_to_slot_attendee(row: sql.FindATimeRow) -> SlotAttendee {
  SlotAttendee(
    engineer_id: row.engineer_id,
    name: option.unwrap(row.name, ""),
    attendance: attendance_of(row.attendance),
    timezone: row.timezone,
    offset_minutes: row.offset_minutes,
  )
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
