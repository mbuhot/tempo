import client/page/people/detail/update as detail_update
import gleam/option.{None, Some}
import gleam/time/calendar
import shared/availability/command as availability_command
import shared/command as gateway

fn default_days() -> List(detail_update.DayEdit) {
  [
    detail_update.DayEdit(True, "09:00", "17:00"),
    detail_update.DayEdit(True, "09:00", "17:00"),
    detail_update.DayEdit(True, "09:00", "17:00"),
    detail_update.DayEdit(True, "09:00", "17:00"),
    detail_update.DayEdit(False, "", ""),
    detail_update.DayEdit(False, "", ""),
    detail_update.DayEdit(False, "", ""),
  ]
}

pub fn build_week_command_from_a_valid_form_test() {
  let form =
    detail_update.WeekForm(
      effective: "2026-07-06",
      days: default_days(),
      error: None,
    )
  assert detail_update.build_week_command(1, form)
    == Ok(
      gateway.AvailabilityCommand(
        availability_command.SetWorkSchedule(
          engineer_id: 1,
          effective: calendar.Date(2026, calendar.July, 6),
          days: [
            availability_command.DayHours(0, Some(#("09:00", "17:00"))),
            availability_command.DayHours(1, Some(#("09:00", "17:00"))),
            availability_command.DayHours(2, Some(#("09:00", "17:00"))),
            availability_command.DayHours(3, Some(#("09:00", "17:00"))),
            availability_command.DayHours(4, None),
            availability_command.DayHours(5, None),
            availability_command.DayHours(6, None),
          ],
        ),
      ),
    )
}

pub fn build_week_command_rejects_a_working_day_without_hours_test() {
  let days = [
    detail_update.DayEdit(True, "", ""),
    detail_update.DayEdit(False, "", ""),
    detail_update.DayEdit(False, "", ""),
    detail_update.DayEdit(False, "", ""),
    detail_update.DayEdit(False, "", ""),
    detail_update.DayEdit(False, "", ""),
    detail_update.DayEdit(False, "", ""),
  ]
  let form = detail_update.WeekForm(effective: "2026-07-06", days:, error: None)
  assert detail_update.build_week_command(1, form)
    == Error("Monday needs start and end times")
}

pub fn build_week_command_rejects_a_bad_date_test() {
  let form =
    detail_update.WeekForm(
      effective: "not-a-date",
      days: default_days(),
      error: None,
    )
  assert detail_update.build_week_command(1, form)
    == Error("effective date must be YYYY-MM-DD")
}
