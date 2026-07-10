import client/page/locations
import client/page/people/detail/update as detail_update
import client/ui/op_commands
import client/ui/ops
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

pub fn build_add_focus_block_command_test() {
  let form =
    ops.blank_op_form(
      ops.OpAddFocusBlock,
      calendar.Date(2026, calendar.July, 6),
    )
    |> ops.update_op_form(ops.FEngineerId, "2")
    |> ops.update_op_form(ops.FEffective, "2026-07-08")
    |> ops.update_op_form(ops.FStartsAt, "13:00")
    |> ops.update_op_form(ops.FDurationMinutes, "90")
    |> ops.update_op_form(ops.FTimezone, "America/Los_Angeles")
    |> ops.update_op_form(ops.FTitle, "Design deep-dive")
  assert op_commands.build_command(ops.OpAddFocusBlock, form)
    == Ok(
      gateway.AvailabilityCommand(availability_command.AddFocusBlock(
        engineer_id: 2,
        date: calendar.Date(2026, calendar.July, 8),
        starts_at: "13:00",
        duration_minutes: 90,
        timezone: "America/Los_Angeles",
        title: "Design deep-dive",
      )),
    )
}

pub fn build_remove_focus_block_command_test() {
  let form =
    ops.blank_op_form(
      ops.OpRemoveFocusBlock,
      calendar.Date(2026, calendar.July, 6),
    )
    |> ops.update_op_form(ops.FEngineerId, "2")
    |> ops.update_op_form(ops.FFocusBlockId, "7")
  assert op_commands.build_command(ops.OpRemoveFocusBlock, form)
    == Ok(
      gateway.AvailabilityCommand(availability_command.RemoveFocusBlock(
        engineer_id: 2,
        focus_block_id: 7,
      )),
    )
}

pub fn parse_holiday_lines_accepts_valid_lines_test() {
  let text =
    "AU,AU-NSW,2026-10-05,Labour Day\nGB,,2026-08-31,Summer Bank Holiday\n"
  assert locations.parse_holiday_lines(text)
    == Ok([
      availability_command.HolidayRow(
        "AU",
        "AU-NSW",
        calendar.Date(2026, calendar.October, 5),
        "Labour Day",
      ),
      availability_command.HolidayRow(
        "GB",
        "",
        calendar.Date(2026, calendar.August, 31),
        "Summer Bank Holiday",
      ),
    ])
}

pub fn parse_holiday_lines_rejects_a_malformed_line_test() {
  assert locations.parse_holiday_lines("AU,AU-NSW,not-a-date,Labour Day")
    == Error("line 1: date must be YYYY-MM-DD")
}

pub fn parse_holiday_lines_rejects_empty_input_test() {
  assert locations.parse_holiday_lines("\n\n")
    == Error("no holiday lines found")
}
