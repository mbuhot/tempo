import client/page/schedule
import gleam/option.{None}
import gleam/time/calendar.{Date}
import shared/command
import shared/engagement/command as engagement_command
import shared/schedule/view as schedule_view

fn previewed_schedule() -> schedule_view.Schedule {
  schedule_view.Schedule(
    as_of: Date(2026, calendar.June, 15),
    weeks: [Date(2026, calendar.June, 15)],
    projects: [],
  )
}

fn stale_fetch_schedule() -> schedule_view.Schedule {
  schedule_view.Schedule(
    as_of: Date(2026, calendar.June, 15),
    weeks: [Date(2026, calendar.June, 22)],
    projects: [],
  )
}

fn model_with_active_scenario() -> schedule.Model {
  schedule.Model(
    as_of: Date(2026, calendar.June, 15),
    actor: "Priya Sharma",
    state: schedule.Loaded(previewed_schedule()),
    scenario: [
      command.EngagementCommand(engagement_command.RescheduleProject(
        project_id: 500,
        valid_from: Date(2026, calendar.June, 15),
        valid_to: Date(2026, calendar.December, 1),
      )),
    ],
    preview_on: True,
    selected: None,
    preview_token: 1,
    inspector: None,
    outcomes: [],
    applying: False,
    apply_error: None,
  )
}

pub fn a_stale_plain_fetch_does_not_clobber_an_active_preview_test() {
  let model = model_with_active_scenario()
  let #(updated, _, _) =
    schedule.update(
      model,
      schedule.Fetched(as_of: model.as_of, result: Ok(stale_fetch_schedule())),
    )
  assert updated.state == schedule.Loaded(previewed_schedule())
}
