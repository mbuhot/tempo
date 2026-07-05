import client/page/meetings
import client/ui
import gleam/option
import gleam/result
import gleam/time/calendar
import shared/command as gateway
import shared/meeting/command as meeting_command

pub fn local_time_applies_a_positive_offset_test() {
  assert meetings.local_time("2026-07-10T09:00:00Z", 60) == "10:00"
}

pub fn local_time_applies_a_negative_offset_test() {
  assert meetings.local_time("2026-07-10T09:00:00Z", -420) == "02:00"
}

pub fn build_reschedule_command_test() {
  let form =
    ui.blank_op_form(
      ui.OpRescheduleMeeting,
      calendar.Date(2026, calendar.July, 10),
    )
    |> ui.update_op_form(ui.FMeetingId, "7")
    |> ui.update_op_form(ui.FTimezone, "Europe/London")
    |> ui.update_op_form(ui.FEffective, "2026-07-11")
    |> ui.update_op_form(ui.FStartsAt, "14:00")
    |> ui.update_op_form(ui.FDurationMinutes, "30")
  assert ui.build_command(ui.OpRescheduleMeeting, form)
    == Ok(
      gateway.MeetingCommand(meeting_command.RescheduleMeeting(
        meeting_id: 7,
        timezone: "Europe/London",
        date: calendar.Date(2026, calendar.July, 11),
        starts_at: "14:00",
        duration_minutes: 30,
      )),
    )
}

pub fn build_cancel_command_rejects_missing_id_test() {
  let form =
    ui.blank_op_form(ui.OpCancelMeeting, calendar.Date(2026, calendar.July, 10))
  assert ui.build_command(ui.OpCancelMeeting, form) |> result.is_error
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
      gateway.MeetingCommand(
        meeting_command.ScheduleMeeting(
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
        ),
      ),
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
