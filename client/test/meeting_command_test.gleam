import client/page/meetings/update as meetings
import client/ui/ops
import gleam/http/response
import gleam/option
import gleam/result
import gleam/time/calendar
import rsvp
import shared/command as gateway
import shared/location/view as location_view
import shared/meeting/command as meeting_command
import shared/meeting/view as meeting_view

pub fn local_time_applies_a_positive_offset_test() {
  assert meetings.local_time("2026-07-10T09:00:00Z", 60) == "10:00"
}

pub fn local_time_applies_a_negative_offset_test() {
  assert meetings.local_time("2026-07-10T09:00:00Z", -420) == "02:00"
}

// --- Viewer-local time toggle (#57) ------------------------------------------

pub fn resolve_offset_picks_the_origin_offset_in_origin_mode_test() {
  assert meetings.resolve_offset(meetings.OriginTime, 60, 600) == 60
}

pub fn resolve_offset_picks_the_browser_offset_in_local_mode_test() {
  assert meetings.resolve_offset(meetings.LocalTime, 60, 600) == 600
}

pub fn when_line_renders_the_origin_offset_in_origin_mode_test() {
  assert meetings.when_line(
      meetings.OriginTime,
      "2026-07-10T08:00:00Z",
      60,
      600,
    )
    == "09:00 UTC+01:00"
}

pub fn when_line_renders_the_browser_offset_in_local_mode_test() {
  assert meetings.when_line(meetings.LocalTime, "2026-07-10T08:00:00Z", 60, 600)
    == "18:00 UTC+10:00"
}

pub fn resolve_zone_picks_the_origin_timezone_in_origin_mode_test() {
  assert meetings.resolve_zone(
      meetings.OriginTime,
      "Europe/London",
      "Australia/Sydney",
    )
    == "Europe/London"
}

pub fn resolve_zone_picks_the_browser_timezone_in_local_mode_test() {
  assert meetings.resolve_zone(
      meetings.LocalTime,
      "Europe/London",
      "Australia/Sydney",
    )
    == "Australia/Sydney"
}

pub fn build_reschedule_command_test() {
  let form =
    ops.blank_op_form(
      ops.OpRescheduleMeeting,
      calendar.Date(2026, calendar.July, 10),
    )
    |> ops.update_op_form(ops.FMeetingId, "7")
    |> ops.update_op_form(ops.FTimezone, "Europe/London")
    |> ops.update_op_form(ops.FEffective, "2026-07-11")
    |> ops.update_op_form(ops.FStartsAt, "14:00")
    |> ops.update_op_form(ops.FDurationMinutes, "30")
  assert ops.build_command(ops.OpRescheduleMeeting, form)
    == Ok(
      gateway.MeetingCommand(meeting_command.RescheduleMeeting(
        meeting_id: 7,
        timezone: "Europe/London",
        date: calendar.Date(2026, calendar.July, 11),
        starts_at: "14:00",
        duration_minutes: 30,
        check: meeting_command.AllowOverlap,
      )),
    )
}

pub fn build_cancel_command_rejects_missing_id_test() {
  let form =
    ops.blank_op_form(
      ops.OpCancelMeeting,
      calendar.Date(2026, calendar.July, 10),
    )
  assert ops.build_command(ops.OpCancelMeeting, form) |> result.is_error
}

pub fn build_add_attendee_command_test() {
  let form =
    ops.blank_op_form(ops.OpAddAttendee, calendar.Date(2026, calendar.July, 10))
    |> ops.update_op_form(ops.FMeetingId, "7")
    |> ops.update_op_form(ops.FEngineerId, "3")
    |> ops.update_op_form(ops.FAttendance, "optional")
  assert ops.build_command(ops.OpAddAttendee, form)
    == Ok(
      gateway.MeetingCommand(meeting_command.AddAttendee(
        meeting_id: 7,
        engineer_id: 3,
        attendance: meeting_command.Optional,
      )),
    )
}

pub fn build_remove_attendee_command_test() {
  let form =
    ops.blank_op_form(
      ops.OpRemoveAttendee,
      calendar.Date(2026, calendar.July, 10),
    )
    |> ops.update_op_form(ops.FMeetingId, "7")
    |> ops.update_op_form(ops.FEngineerId, "3")
  assert ops.build_command(ops.OpRemoveAttendee, form)
    == Ok(
      gateway.MeetingCommand(meeting_command.RemoveAttendee(
        meeting_id: 7,
        engineer_id: 3,
      )),
    )
}

pub fn build_schedule_command_from_a_valid_form_test() {
  let form =
    meetings.CreateForm(
      title: "Kickoff",
      timezone: "Europe/London",
      date: "2026-07-10",
      starts_at: "09:30",
      duration_minutes: "45",
      location: "",
      client_id: "",
      project_id: "3",
      attendees: [
        meetings.Attendee(1, meeting_command.Required),
        meetings.Attendee(2, meeting_command.Optional),
      ],
      query: "",
      error: option.None,
    )
  assert meetings.build_schedule_command(form)
    == Ok(
      gateway.MeetingCommand(meeting_command.ScheduleMeeting(
        title: "Kickoff",
        timezone: "Europe/London",
        date: calendar.Date(2026, calendar.July, 10),
        starts_at: "09:30",
        duration_minutes: 45,
        location: option.None,
        client_id: option.None,
        project_id: option.Some(3),
        attendees: [
          #(1, meeting_command.Required),
          #(2, meeting_command.Optional),
        ],
        check: meeting_command.AllowOverlap,
      )),
    )
}

pub fn build_schedule_command_requires_an_attendee_test() {
  let form =
    meetings.CreateForm(
      title: "Kickoff",
      timezone: "Europe/London",
      date: "2026-07-10",
      starts_at: "09:30",
      duration_minutes: "45",
      location: "",
      client_id: "",
      project_id: "",
      attendees: [],
      query: "",
      error: option.None,
    )
  assert meetings.build_schedule_command(form)
    == Error("add at least one attendee")
}

pub fn build_schedule_command_rejects_a_non_numeric_project_id_test() {
  let form =
    meetings.CreateForm(
      title: "Kickoff",
      timezone: "Europe/London",
      date: "2026-07-10",
      starts_at: "09:30",
      duration_minutes: "45",
      location: "",
      client_id: "",
      project_id: "3x",
      attendees: [meetings.Attendee(1, meeting_command.Required)],
      query: "",
      error: option.None,
    )
  assert meetings.build_schedule_command(form)
    == Error("project id must be a number")
}

// --- Find-a-time wizard -------------------------------------------------------

/// A valid finder form (one required attendee, a searchable window, a filled
/// title) that individual tests override via record update — every override
/// is still an explicit, deterministic value.
fn finder_form() -> meetings.FinderForm {
  meetings.FinderForm(
    attendees: [
      meetings.Attendee(1, meeting_command.Required),
      meetings.Attendee(2, meeting_command.Optional),
    ],
    query: "",
    project_choice: "",
    booking_project_id: option.None,
    from_date: "2026-06-15",
    to_date: "2026-06-19",
    duration_minutes: "60",
    timezone: "Europe/London",
    title: "Kickoff",
    results: meetings.NotSearched,
    error: option.None,
  )
}

pub fn slot_local_start_applies_a_positive_offset_test() {
  assert meetings.slot_local_start("2026-07-10T09:00:00Z", 60)
    == #(calendar.Date(2026, calendar.July, 10), "10:00")
}

pub fn slot_local_start_applies_a_negative_offset_test() {
  assert meetings.slot_local_start("2026-07-10T09:00:00Z", -420)
    == #(calendar.Date(2026, calendar.July, 10), "02:00")
}

pub fn slot_local_start_crosses_midnight_into_the_next_day_test() {
  assert meetings.slot_local_start("2026-07-10T23:30:00Z", 60)
    == #(calendar.Date(2026, calendar.July, 11), "00:30")
}

pub fn slot_local_start_crosses_midnight_into_the_previous_day_test() {
  assert meetings.slot_local_start("2026-07-10T00:30:00Z", -420)
    == #(calendar.Date(2026, calendar.July, 9), "17:30")
}

pub fn partition_attendee_ids_splits_required_from_optional_test() {
  assert meetings.partition_attendee_ids(finder_form().attendees) == #([1], [2])
}

pub fn partition_attendee_ids_dedupes_and_required_wins_test() {
  let attendees = [
    meetings.Attendee(2, meeting_command.Optional),
    meetings.Attendee(2, meeting_command.Required),
    meetings.Attendee(3, meeting_command.Optional),
  ]
  assert meetings.partition_attendee_ids(attendees) == #([2], [3])
}

pub fn finder_add_ids_keeps_existing_attendance_and_dedupes_test() {
  let form =
    meetings.FinderForm(..finder_form(), attendees: [
      meetings.Attendee(2, meeting_command.Optional),
    ])
  let updated = meetings.finder_add_ids(form, [2, 3])
  assert updated.attendees
    == [
      meetings.Attendee(2, meeting_command.Optional),
      meetings.Attendee(3, meeting_command.Required),
    ]
}

pub fn build_search_url_from_a_filled_form_test() {
  assert meetings.build_search_url(finder_form())
    == Ok(
      "/api/meetings/find-a-time?from=2026-06-15&to=2026-06-19&tz=Europe/London&duration=60&required=1&optional=2",
    )
}

pub fn build_search_url_requires_a_required_attendee_test() {
  let form =
    meetings.FinderForm(..finder_form(), attendees: [
      meetings.Attendee(2, meeting_command.Optional),
    ])
  assert meetings.build_search_url(form)
    == Error("add at least one required attendee")
}

pub fn build_search_url_requires_a_timezone_test() {
  let form = meetings.FinderForm(..finder_form(), timezone: "")
  assert meetings.build_search_url(form) == Error("timezone is required")
}

pub fn build_search_url_requires_a_positive_duration_test() {
  let form = meetings.FinderForm(..finder_form(), duration_minutes: "0")
  assert meetings.build_search_url(form)
    == Error("duration must be a positive number of minutes")
}

pub fn build_search_url_requires_from_on_or_before_to_test() {
  let form =
    meetings.FinderForm(
      ..finder_form(),
      from_date: "2026-06-19",
      to_date: "2026-06-15",
    )
  assert meetings.build_search_url(form)
    == Error("from date must be on or before to date")
}

pub fn build_finder_schedule_command_from_a_filled_form_test() {
  let form =
    meetings.FinderForm(..finder_form(), booking_project_id: option.Some(300))
  let slot =
    meeting_view.CandidateSlot(
      starts_at: "2026-06-15T23:00:00Z",
      ends_at: "2026-06-16T00:00:00Z",
      attendees: [],
      viewer_offset_minutes: 60,
    )
  assert meetings.build_finder_schedule_command(form, slot)
    == Ok(
      gateway.MeetingCommand(meeting_command.ScheduleMeeting(
        title: "Kickoff",
        timezone: "Europe/London",
        date: calendar.Date(2026, calendar.June, 16),
        starts_at: "00:00",
        duration_minutes: 60,
        location: option.None,
        client_id: option.None,
        project_id: option.Some(300),
        attendees: [
          #(1, meeting_command.Required),
          #(2, meeting_command.Optional),
        ],
        check: meeting_command.RequireFree,
      )),
    )
}

pub fn build_finder_schedule_command_trims_a_padded_timezone_test() {
  let form =
    meetings.FinderForm(
      ..finder_form(),
      timezone: " Europe/London ",
      booking_project_id: option.Some(300),
    )
  let slot =
    meeting_view.CandidateSlot(
      starts_at: "2026-06-15T23:00:00Z",
      ends_at: "2026-06-16T00:00:00Z",
      attendees: [],
      viewer_offset_minutes: 60,
    )
  assert meetings.build_finder_schedule_command(form, slot)
    == Ok(
      gateway.MeetingCommand(meeting_command.ScheduleMeeting(
        title: "Kickoff",
        timezone: "Europe/London",
        date: calendar.Date(2026, calendar.June, 16),
        starts_at: "00:00",
        duration_minutes: 60,
        location: option.None,
        client_id: option.None,
        project_id: option.Some(300),
        attendees: [
          #(1, meeting_command.Required),
          #(2, meeting_command.Optional),
        ],
        check: meeting_command.RequireFree,
      )),
    )
}

pub fn build_finder_schedule_command_requires_a_title_test() {
  let form = meetings.FinderForm(..finder_form(), title: "")
  let slot =
    meeting_view.CandidateSlot(
      starts_at: "2026-06-15T23:00:00Z",
      ends_at: "2026-06-16T00:00:00Z",
      attendees: [],
      viewer_offset_minutes: 60,
    )
  assert meetings.build_finder_schedule_command(form, slot)
    == Error("title is required")
}

pub fn is_slot_taken_detects_the_slot_taken_error_tag_test() {
  let error =
    rsvp.HttpError(response.Response(
      status: 409,
      headers: [],
      body: "{\"error\":\"slot_taken\",\"detail\":\"a required attendee is no longer free for that window\"}",
    ))
  assert meetings.is_slot_taken(error)
}

pub fn is_slot_taken_is_false_for_a_different_error_tag_test() {
  let error =
    rsvp.HttpError(response.Response(
      status: 422,
      headers: [],
      body: "{\"error\":\"invalid_value\",\"detail\":\"bad\"}",
    ))
  assert !meetings.is_slot_taken(error)
}

pub fn is_slot_taken_is_false_for_a_network_error_test() {
  assert !meetings.is_slot_taken(rsvp.NetworkError)
}

// --- Find-a-time wizard: the Timezone select's options + reset rule ---------

/// An engineer located in `timezone` as-of the fixture's (arbitrary) date.
fn located_engineer(
  engineer_id: Int,
  name: String,
  timezone: String,
) -> location_view.EngineerLocation {
  location_view.EngineerLocation(
    engineer_id:,
    name:,
    location: option.Some(location_view.LocationRecord(
      country: "UK",
      region: option.None,
      timezone:,
      valid_from: calendar.Date(2020, calendar.January, 1),
      valid_to: option.None,
      utc_offset_minutes: 0,
    )),
  )
}

pub fn finder_timezone_options_dedupes_in_attendee_order_test() {
  let roster = [
    located_engineer(1, "A", "Europe/London"),
    located_engineer(2, "B", "America/Los_Angeles"),
    located_engineer(3, "C", "Europe/London"),
  ]
  let attendees = [
    meetings.Attendee(1, meeting_command.Required),
    meetings.Attendee(2, meeting_command.Optional),
    meetings.Attendee(3, meeting_command.Required),
  ]
  assert meetings.finder_timezone_options(attendees, roster)
    == ["Europe/London", "America/Los_Angeles", "UTC"]
}

pub fn finder_timezone_options_always_ends_with_utc_test() {
  assert meetings.finder_timezone_options([], []) == ["UTC"]
}

pub fn finder_timezone_options_skips_an_unlocated_attendee_test() {
  let roster = [
    location_view.EngineerLocation(
      engineer_id: 1,
      name: "A",
      location: option.None,
    ),
  ]
  let attendees = [meetings.Attendee(1, meeting_command.Required)]
  assert meetings.finder_timezone_options(attendees, roster) == ["UTC"]
}

pub fn finder_timezone_options_does_not_duplicate_an_attendee_already_in_utc_test() {
  let roster = [located_engineer(1, "A", "UTC")]
  let attendees = [meetings.Attendee(1, meeting_command.Required)]
  assert meetings.finder_timezone_options(attendees, roster) == ["UTC"]
}

pub fn reconcile_finder_timezone_keeps_a_still_valid_selection_test() {
  assert meetings.reconcile_finder_timezone("America/Los_Angeles", [
      "Europe/London", "America/Los_Angeles", "UTC",
    ])
    == "America/Los_Angeles"
}

pub fn reconcile_finder_timezone_resets_to_the_first_option_test() {
  assert meetings.reconcile_finder_timezone("Europe/Paris", [
      "Europe/London", "UTC",
    ])
    == "Europe/London"
}

pub fn reconcile_finder_timezone_resets_to_utc_with_no_attendees_test() {
  assert meetings.reconcile_finder_timezone("", ["UTC"]) == "UTC"
}
