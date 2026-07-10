//// The Meetings page's Origin time / Local time toggle (#57): the display-mode
//// type, the offset/zone/wall-clock arithmetic that renders a wire instant in
//// whichever zone `mode` selects, and the shared attendee/slot local-time
//// formatting the table row and the find-a-time slot both draw from.

import client/time
import gleam/float
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/string
import gleam/time/calendar.{type Date}
import gleam/time/duration
import gleam/time/timestamp

/// The Meetings page's When-column display mode (#57): `OriginTime` renders a
/// meeting in the zone it was scheduled in (today's rendering), `LocalTime` in
/// the viewer's own browser zone. Page-local UI state — never persisted, and
/// reset to `OriginTime` on every navigation to the page (`init`'s default).
pub type TimeDisplay {
  OriginTime
  LocalTime
}

/// An ISO-8601 UTC instant shifted by `offset_minutes` (minutes east of UTC)
/// and split into its local calendar date and wall-clock time — the shared
/// arithmetic behind `local_time`, `local_date`, and the reschedule prefill.
fn shift_local(
  starts_at_iso: String,
  offset_minutes: Int,
) -> #(Date, calendar.TimeOfDay) {
  let assert Ok(instant) = timestamp.parse_rfc3339(starts_at_iso)
  let shifted = timestamp.add(instant, duration.minutes(offset_minutes))
  timestamp.to_calendar(shifted, calendar.utc_offset)
}

/// The wall-clock "HH:MM" for `starts_at` (an ISO-8601 UTC instant) shifted by
/// `offset_minutes` (minutes east of UTC), so the caller can render a meeting's
/// canonical time or any attendee's local time from the same wire instant.
pub fn local_time(starts_at_iso: String, offset_minutes: Int) -> String {
  let #(_date, time_of_day) = shift_local(starts_at_iso, offset_minutes)
  pad2(time_of_day.hours) <> ":" <> pad2(time_of_day.minutes)
}

/// The local calendar date for `starts_at` shifted by `offset_minutes` — used to
/// pre-fill the reschedule form's date field from a meeting's own timezone and
/// to resolve a booked find-a-time slot's local calendar date.
pub fn local_date(starts_at_iso: String, offset_minutes: Int) -> Date {
  let #(date, _time_of_day) = shift_local(starts_at_iso, offset_minutes)
  date
}

/// Which of a pair of offsets/zones `mode` selects: `origin` (the meeting's
/// canonical zone, or the find-a-time wizard's searched zone) for
/// `OriginTime`, `browser` (the viewer's own browser-read zone, from
/// `browser_time` — kept out of this module so the dispatch stays pure and
/// testable) for `LocalTime`. Shared by every `When`-column and find-a-time
/// slot render, so origin and viewer-local can never resolve inconsistently.
pub fn resolve_offset(
  mode: TimeDisplay,
  origin_offset_minutes: Int,
  browser_offset_minutes: Int,
) -> Int {
  case mode {
    OriginTime -> origin_offset_minutes
    LocalTime -> browser_offset_minutes
  }
}

/// The `When`-column's own line — "HH:MM UTC±HH:MM" — using the origin
/// (canonical) offset in `OriginTime` mode or the browser offset in
/// `LocalTime` mode.
pub fn when_line(
  mode: TimeDisplay,
  starts_at_iso: String,
  origin_offset_minutes: Int,
  browser_offset_minutes: Int,
) -> String {
  let offset =
    resolve_offset(mode, origin_offset_minutes, browser_offset_minutes)
  local_time(starts_at_iso, offset) <> " " <> time.utc_offset(offset)
}

/// The zone NAME to display beneath a time — the meeting's own `meeting_tz`
/// (or the wizard's searched zone) in `OriginTime` mode, the browser's own
/// zone in `LocalTime` mode.
pub fn resolve_zone(
  mode: TimeDisplay,
  origin_timezone: String,
  browser_timezone: String,
) -> String {
  case mode {
    OriginTime -> origin_timezone
    LocalTime -> browser_timezone
  }
}

/// The whole-minute span between two ISO-8601 UTC instants — used to pre-fill
/// the reschedule form's duration field from a meeting's `starts_at`/`ends_at`.
pub fn minutes_between(starts_at_iso: String, ends_at_iso: String) -> Int {
  let assert Ok(starts_at) = timestamp.parse_rfc3339(starts_at_iso)
  let assert Ok(ends_at) = timestamp.parse_rfc3339(ends_at_iso)
  float.round(
    duration.to_seconds(timestamp.difference(starts_at, ends_at)) /. 60.0,
  )
}

fn pad2(value: Int) -> String {
  int.to_string(value) |> string.pad_start(to: 2, with: "0")
}

/// A candidate slot's UTC `starts_at_iso`, shifted by `viewer_offset_minutes`
/// into the viewer-local calendar date and "HH:MM" wall-clock time the booking
/// command needs — the client has no timezone database, so the server ships
/// the offset and this is where it gets applied to a BOOKING (as opposed to a
/// read-only local-time render, which uses `local_time` alone).
pub fn slot_local_start(
  starts_at_iso: String,
  viewer_offset_minutes: Int,
) -> #(Date, String) {
  #(
    local_date(starts_at_iso, viewer_offset_minutes),
    local_time(starts_at_iso, viewer_offset_minutes),
  )
}

/// An attendee's local wall-clock time at `starts_at`, or `"no location"` when
/// the attendee has no as-of location to resolve an offset from — shared by
/// the meeting table's attendee rows and the find-a-time slot's attendee list.
pub fn attendee_local_time(
  starts_at: String,
  local_offset_minutes: Option(Int),
) -> String {
  case local_offset_minutes {
    Some(offset) -> local_time(starts_at, offset)
    None -> "no location"
  }
}
