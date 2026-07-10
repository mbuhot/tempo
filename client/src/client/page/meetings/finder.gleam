//// The Meetings page's find-a-time wizard: the `FinderForm` criteria model,
//// its field enum and search-result states, the roster/timezone/attendee-id
//// helpers the criteria builder draws from, and the pure
//// validation/URL-building/command-assembly logic the update fold and its
//// tests draw from.

import client/api
import client/page/meetings/time_display.{slot_local_start}
import client/time
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/time/calendar.{type Date}
import rsvp
import shared/command as gateway
import shared/location/view.{type EngineerLocation} as _
import shared/meeting/command.{Required}
import shared/meeting/view.{type CandidateSlot} as _

/// One row of a form's attendee list: an engineer plus the `Attendance` they
/// are invited with — shared by the "Schedule meeting" create form and the
/// find-a-time wizard's own attendee list.
pub type Attendee {
  Attendee(engineer_id: Int, attendance: command.Attendance)
}

/// The find-a-time wizard's search outcome: no search run yet, a search
/// in flight, a completed search, or a completed RE-search run automatically
/// because the presenter's booked pick was just taken by someone else — a
/// distinct state rather than a "stale" boolean flag, so the view can name it.
pub type FinderResults {
  NotSearched
  Searching
  Found(slots: List(CandidateSlot))
  SlotTaken(slots: List(CandidateSlot))
}

/// Names a slot of the `FinderForm` — the wizard's own field enum, mirroring
/// `CreateField` since `find_time`/`ScheduleMeeting` are also composed directly
/// rather than through the scalar op-form engine.
pub type FinderField {
  FinderTitle
  FinderProjectChoice
  FinderFromDate
  FinderToDate
  FinderDurationMinutes
  FinderTimezone
}

/// The "Find a time" wizard: the criteria (attendees, search window, duration,
/// timezone), the meeting title to book, and the current `results`.
/// `booking_project_id` is set only once "Fill from project" has actually run,
/// so a booked meeting attaches to that project exactly when the wizard was
/// used to staff it from one — an id, not a bare flag, doubling as both "was it
/// used" and "which project".
pub type FinderForm {
  FinderForm(
    attendees: List(Attendee),
    query: String,
    project_choice: String,
    booking_project_id: Option(Int),
    from_date: String,
    to_date: String,
    duration_minutes: String,
    timezone: String,
    title: String,
    results: FinderResults,
    error: Option(String),
  )
}

/// A blank finder form, opened by the "Find a time" launcher: the search window
/// defaults to `as_of .. as_of+13 days`, duration to 60 minutes, timezone blank —
/// the caller (`FinderOpened`) runs it through `finder_reconcile_timezone` right
/// away, which snaps the blank value to `"UTC"` (no attendees yet).
pub fn blank_finder_form(as_of: Date) -> FinderForm {
  FinderForm(
    attendees: [],
    query: "",
    project_choice: "",
    booking_project_id: None,
    from_date: time.iso_date(as_of),
    to_date: time.iso_date(plus_days(as_of, 13)),
    duration_minutes: "60",
    timezone: "",
    title: "",
    results: NotSearched,
    error: None,
  )
}

fn plus_days(date: Date, days: Int) -> Date {
  time.day_index_to_date(time.date_to_day_index(date) + days)
}

/// Fold a `FinderFieldEdited` edit into the matching `FinderForm` slot.
pub fn update_finder_field(
  form: FinderForm,
  field: FinderField,
  value: String,
) -> FinderForm {
  case field {
    FinderTitle -> FinderForm(..form, title: value)
    FinderProjectChoice -> FinderForm(..form, project_choice: value)
    FinderFromDate -> FinderForm(..form, from_date: value)
    FinderToDate -> FinderForm(..form, to_date: value)
    FinderDurationMinutes -> FinderForm(..form, duration_minutes: value)
    FinderTimezone -> FinderForm(..form, timezone: value)
  }
}

/// The roster narrowed to engineers with a location as-of the date — the only
/// engineers any wizard picker (search, add everyone, fill from project) can
/// ever offer, since an unlocated engineer can never produce a free slot.
pub fn located_roster(
  roster: List(EngineerLocation),
) -> List(EngineerLocation) {
  list.filter(roster, fn(entry) { option.is_some(entry.location) })
}

/// Add every id in `ids` to `form.attendees` as `Required`, skipping any id
/// already present so an existing attendee KEEPS whichever attendance the
/// presenter already chose for them.
pub fn finder_add_ids(form: FinderForm, ids: List(Int)) -> FinderForm {
  FinderForm(..form, attendees: list.fold(ids, form.attendees, add_one))
}

fn add_one(attendees: List(Attendee), engineer_id: Int) -> List(Attendee) {
  case
    list.any(attendees, fn(attendee) { attendee.engineer_id == engineer_id })
  {
    True -> attendees
    False ->
      list.append(attendees, [Attendee(engineer_id:, attendance: Required)])
  }
}

/// The distinct timezones of `attendees`' roster locations, in attendee order,
/// with `"UTC"` always appended last (deduped against an attendee already
/// located there) — the find-a-time wizard's `Timezone` select options. An
/// attendee with no as-of location contributes no option.
pub fn finder_timezone_options(
  attendees: List(Attendee),
  roster: List(EngineerLocation),
) -> List(String) {
  let zones =
    attendees
    |> list.filter_map(fn(attendee) {
      attendee_timezone(attendee.engineer_id, roster)
    })
    |> list.unique
    |> list.filter(fn(timezone) { timezone != "UTC" })
  list.append(zones, ["UTC"])
}

fn attendee_timezone(
  engineer_id: Int,
  roster: List(EngineerLocation),
) -> Result(String, Nil) {
  use entry <- result.try(
    list.find(roster, fn(entry) { entry.engineer_id == engineer_id }),
  )
  use location <- result.try(option.to_result(entry.location, Nil))
  Ok(location.timezone)
}

/// Snap `current` to `options`: kept if still present, otherwise reset to the
/// first option (an attendee's own zone, or `"UTC"` once the attendee list is
/// empty) — mirroring `ops.reconcile_ref`'s stale-selection reset.
pub fn reconcile_finder_timezone(
  current: String,
  options: List(String),
) -> String {
  case list.contains(options, current), options {
    True, _ -> current
    False, [first, ..] -> first
    False, [] -> current
  }
}

/// Reconcile `form.timezone` against the options its CURRENT attendees now
/// offer — called everywhere the attendee list changes, so the selection never
/// points at a zone no attendee is in.
pub fn finder_reconcile_timezone(
  form: FinderForm,
  roster: List(EngineerLocation),
) -> FinderForm {
  let options = finder_timezone_options(form.attendees, roster)
  FinderForm(
    ..form,
    timezone: reconcile_finder_timezone(form.timezone, options),
  )
}

/// Split `attendees` into (required ids, optional ids), each deduplicated and
/// disjoint — an id present as both stays only in `required` — mirroring the
/// server's own `find_time` dedupe guard.
pub fn partition_attendee_ids(
  attendees: List(Attendee),
) -> #(List(Int), List(Int)) {
  let required =
    attendees
    |> list.filter(fn(attendee) { attendee.attendance == command.Required })
    |> list.map(fn(attendee) { attendee.engineer_id })
    |> list.unique
  let optional =
    attendees
    |> list.filter(fn(attendee) { attendee.attendance == command.Optional })
    |> list.map(fn(attendee) { attendee.engineer_id })
    |> list.unique
    |> list.filter(fn(id) { !list.contains(required, id) })
  #(required, optional)
}

/// Parse a `YYYY-MM-DD` field into a `calendar.Date`, or a message naming the
/// expected shape.
fn parse_date(raw: String) -> Result(Date, String) {
  time.parse_iso_date(string.trim(raw))
  |> result.replace_error("date must be YYYY-MM-DD")
}

/// Validate the wizard's criteria and build the `GET /api/meetings/find-a-time`
/// query string, or report the first thing missing: at least one required
/// attendee, a non-empty timezone, a positive duration, and `from` on or before
/// `to`.
pub fn build_search_url(form: FinderForm) -> Result(String, String) {
  use from <- result.try(parse_date(form.from_date))
  use to <- result.try(parse_date(form.to_date))
  use duration <- result.try(
    int.parse(form.duration_minutes)
    |> result.replace_error("duration must be a number"),
  )
  let #(required, optional) = partition_attendee_ids(form.attendees)
  let timezone = string.trim(form.timezone)
  case
    required,
    timezone,
    duration > 0,
    time.date_to_day_index(from) <= time.date_to_day_index(to)
  {
    [], _, _, _ -> Error("add at least one required attendee")
    _, "", _, _ -> Error("timezone is required")
    _, _, False, _ -> Error("duration must be a positive number of minutes")
    _, _, _, False -> Error("from date must be on or before to date")
    _, _, _, _ ->
      Ok(
        "/api/meetings/find-a-time?from="
        <> time.iso_date(from)
        <> "&to="
        <> time.iso_date(to)
        <> "&tz="
        <> timezone
        <> "&duration="
        <> int.to_string(duration)
        <> "&required="
        <> ids_to_csv(required)
        <> optional_ids_query(optional),
      )
  }
}

fn ids_to_csv(ids: List(Int)) -> String {
  ids |> list.map(int.to_string) |> string.join(",")
}

fn optional_ids_query(optional: List(Int)) -> String {
  case optional {
    [] -> ""
    ids -> "&optional=" <> ids_to_csv(ids)
  }
}

/// Fold a `FinderSlotsFetched`/`FinderSlotsRefetchedAfterTaken` outcome into
/// the form: on success wrap the slots in `wrap` (`Found` for a normal search,
/// `SlotTaken` for the automatic re-search after a booking collision); on
/// failure fall back to `NotSearched` and surface the error inline.
pub fn apply_slots_fetched(
  form: FinderForm,
  wrap: fn(List(CandidateSlot)) -> FinderResults,
  result: Result(List(CandidateSlot), rsvp.Error(String)),
) -> FinderForm {
  case result {
    Ok(slots) -> FinderForm(..form, results: wrap(slots), error: None)
    Error(error) ->
      FinderForm(
        ..form,
        results: NotSearched,
        error: Some(api.describe_error(error)),
      )
  }
}

/// The pure, testable heart of booking a slot: validate + assemble a
/// `ScheduleMeeting(check: RequireFree)` command from the wizard's criteria and
/// the chosen slot, or report the first thing missing.
pub fn build_finder_schedule_command(
  form: FinderForm,
  slot: CandidateSlot,
) -> Result(gateway.Command, String) {
  use duration <- result.try(
    int.parse(form.duration_minutes)
    |> result.replace_error("duration must be a number"),
  )
  case string.trim(form.title), form.attendees {
    "", _ -> Error("title is required")
    _, [] -> Error("add at least one attendee")
    title, attendees -> {
      let #(date, starts_at) =
        slot_local_start(slot.starts_at, slot.viewer_offset_minutes)
      Ok(
        gateway.MeetingCommand(command.ScheduleMeeting(
          title:,
          timezone: string.trim(form.timezone),
          date:,
          starts_at:,
          duration_minutes: duration,
          location: None,
          client_id: None,
          project_id: form.booking_project_id,
          attendees: list.map(attendees, fn(attendee) {
            #(attendee.engineer_id, attendee.attendance)
          }),
          check: command.RequireFree,
        )),
      )
    }
  }
}

/// Whether `error` is the operations handler's `slot_taken` rejection — the
/// wizard automatically re-searches on this ONE failure and surfaces every
/// other error inline instead.
pub fn is_slot_taken(error: rsvp.Error(String)) -> Bool {
  case error {
    rsvp.HttpError(response) ->
      gateway.decode_error_tag(response.body) == Ok("slot_taken")
    _ -> False
  }
}

/// The display name for `engineer_id` in `roster`, or a fallback naming the id
/// when the roster hasn't loaded them yet — shared by the create form's and
/// the find-a-time wizard's own attendee-row rendering.
pub fn roster_name(roster: List(EngineerLocation), engineer_id: Int) -> String {
  roster
  |> list.find(fn(entry) { entry.engineer_id == engineer_id })
  |> result.map(fn(entry) { entry.name })
  |> result.unwrap("Engineer #" <> int.to_string(engineer_id))
}
