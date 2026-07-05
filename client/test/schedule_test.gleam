import client/page/schedule
import client/page/schedule/inspector
import client/page/schedule/scenario
import gleam/option.{None, Some}
import gleam/time/calendar.{Date}
import shared/allocation/command as allocation_command
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
  scenario.Model(
    as_of: Date(2026, calendar.June, 15),
    actor: "Priya Sharma",
    state: scenario.Loaded(previewed_schedule()),
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
      scenario.Fetched(as_of: model.as_of, result: Ok(stale_fetch_schedule())),
    )
  assert updated.state == scenario.Loaded(previewed_schedule())
}

fn model_with_selected_project() -> schedule.Model {
  scenario.Model(
    as_of: Date(2026, calendar.June, 15),
    actor: "Priya Sharma",
    state: scenario.Loading,
    scenario: [],
    preview_on: False,
    selected: Some(500),
    preview_token: 0,
    inspector: None,
    outcomes: [],
    applying: False,
    apply_error: None,
  )
}

pub fn drafting_a_roll_off_adds_it_to_the_scenario_and_bumps_the_preview_test() {
  let model = model_with_selected_project()
  let #(updated, _, _) =
    schedule.update(model, scenario.RollOffDrafted(engineer_id: 42))
  assert updated.scenario
    == [
      command.AllocationCommand(allocation_command.RollOff(
        engineer_id: 42,
        project_id: 500,
        effective: model.as_of,
      )),
    ]
  assert updated.preview_on == True
  assert updated.preview_token == model.preview_token + 1
}

pub fn editing_a_fraction_drafts_a_change_and_a_second_edit_replaces_it_test() {
  let model = model_with_selected_project()
  let #(first_edit, _, _) =
    schedule.update(
      model,
      scenario.FractionChanged(engineer_id: 42, value: "0.6"),
    )
  assert first_edit.scenario
    == [
      command.AllocationCommand(allocation_command.ChangeAllocationFraction(
        engineer_id: 42,
        project_id: 500,
        fraction: 0.6,
        effective: model.as_of,
      )),
    ]

  let #(second_edit, _, _) =
    schedule.update(
      first_edit,
      scenario.FractionChanged(engineer_id: 42, value: "0.4"),
    )
  assert second_edit.scenario
    == [
      command.AllocationCommand(allocation_command.ChangeAllocationFraction(
        engineer_id: 42,
        project_id: 500,
        fraction: 0.4,
        effective: model.as_of,
      )),
    ]
}

fn project_with_lane_and_no_requirement_lines() -> schedule_view.ProjectSchedule {
  schedule_view.ProjectSchedule(
    project_id: 700,
    title: "Nimbus Platform",
    client: "Nimbus Co",
    run_from: Date(2026, calendar.January, 1),
    run_to: Date(2026, calendar.December, 31),
    lanes: [
      schedule_view.EngineerLane(
        engineer_id: 88,
        name: "Priya Sharma",
        level: 4,
        cells: [schedule_view.Working(fraction: 0.6, over_allocated: False)],
      ),
    ],
    lines: [],
    team: [],
    capabilities: [],
    annotation: None,
  )
}

pub fn a_lane_engineer_appears_as_a_team_row_with_zero_requirement_lines_test() {
  let weeks = [Date(2026, calendar.June, 15)]
  let project = project_with_lane_and_no_requirement_lines()
  assert inspector.team_rows(weeks, project, Date(2026, calendar.June, 15))
    == [
      inspector.TeamRow(
        engineer_id: 88,
        name: "Priya Sharma",
        level: 4,
        fraction: 0.6,
      ),
    ]
}
