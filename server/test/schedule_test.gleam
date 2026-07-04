import gleam/list
import gleam/option.{None}
import gleam/time/calendar.{Date}
import shared/schedule/view as shared_schedule
import tempo/server/schedule/view as schedule_view
import test_pool

pub fn timeline_buckets_twelve_weeks_from_the_as_of_monday_test() {
  let assert Ok(schedule) =
    schedule_view.timeline(test_pool.db(), Date(2026, calendar.June, 15))
  assert list.length(schedule.weeks) == 12
  assert list.first(schedule.weeks) == Ok(Date(2026, calendar.June, 15))
  assert list.last(schedule.weeks) == Ok(Date(2026, calendar.August, 31))
}

pub fn timeline_lists_projects_overlapping_the_window_test() {
  let assert Ok(schedule) =
    schedule_view.timeline(test_pool.db(), Date(2026, calendar.June, 15))
  let titles = list.map(schedule.projects, fn(project) { project.title })
  assert titles
    == [
      "Data Platform", "Edge Analytics", "Inventory Sync", "Ledger Migration",
      "Platform Telemetry",
    ]
}

pub fn a_leave_week_renders_on_leave_and_counts_zero_test() {
  let assert Ok(schedule) =
    schedule_view.timeline(test_pool.db(), Date(2026, calendar.June, 15))
  let assert Ok(data_platform) =
    list.find(schedule.projects, fn(project) { project.project_id == 300 })
  let assert Ok(aisha) =
    list.find(data_platform.lanes, fn(lane) { lane.engineer_id == 3 })
  let assert [first_week, second_week, ..] = aisha.cells
  assert first_week == shared_schedule.OnLeave
  assert second_week
    == shared_schedule.Working(fraction: 1.0, over_allocated: False)
}

pub fn capability_gaps_use_the_rollup_qualifying_rule_test() {
  let assert Ok(schedule) =
    schedule_view.timeline(test_pool.db(), Date(2026, calendar.June, 15))
  let assert Ok(ledger) =
    list.find(schedule.projects, fn(project) { project.project_id == 100 })
  let assert Ok(shared_schedule.RequirementLine(gaps: payments_gaps, ..)) =
    list.find(ledger.lines, fn(line) {
      case line.kind {
        shared_schedule.CapabilityLine(capability_id: 1, ..) -> True
        _ -> False
      }
    })
  assert payments_gaps == list.repeat(1.5, 12)
}

pub fn level_gaps_open_when_the_requirement_window_starts_test() {
  let assert Ok(schedule) =
    schedule_view.timeline(test_pool.db(), Date(2026, calendar.June, 15))
  let assert Ok(edge) =
    list.find(schedule.projects, fn(project) { project.project_id == 500 })
  let assert Ok(shared_schedule.RequirementLine(gaps: level_three_gaps, ..)) =
    list.find(edge.lines, fn(line) {
      line.kind == shared_schedule.LevelLine(level: 3)
    })
  assert level_three_gaps
    == list.append(list.repeat(0.0, 7), list.repeat(2.0, 5))
  assert edge.team
    == [
      shared_schedule.OpenSeat(level: 3, fraction: 1.0),
      shared_schedule.OpenSeat(level: 3, fraction: 1.0),
      shared_schedule.OpenSeat(level: 4, fraction: 1.0),
      shared_schedule.OpenSeat(level: 5, fraction: 0.5),
    ]
  assert edge.annotation == None
}

pub fn candidates_list_every_qualifier_with_free_fraction_test() {
  let assert Ok(candidates) =
    schedule_view.candidates(
      test_pool.db(),
      Date(2026, calendar.June, 15),
      500,
      3,
      Date(2026, calendar.August, 1),
      Date(2027, calendar.January, 1),
    )
  let names =
    list.map(candidates, fn(candidate) {
      #(candidate.name, candidate.level, candidate.free)
    })
  assert names
    == [
      #("Aisha Okafor", 6, 0.0),
      #("Priya Sharma", 5, 0.0),
      #("Marcus Chen", 4, 0.0),
    ]
}
