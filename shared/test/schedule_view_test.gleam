import gleam/json
import gleam/option.{None, Some}
import gleam/time/calendar.{Date}
import shared/schedule/view

fn round_trip_schedule(schedule: view.Schedule) -> Result(view.Schedule, _) {
  view.encode_schedule(schedule)
  |> json.to_string
  |> json.parse(view.schedule_decoder())
}

pub fn schedule_codec_round_trip_test() {
  let schedule =
    view.Schedule(
      as_of: Date(2026, calendar.June, 15),
      weeks: [Date(2026, calendar.June, 15), Date(2026, calendar.June, 22)],
      projects: [
        view.ProjectSchedule(
          project_id: 500,
          title: "Edge Analytics",
          client: "Initech Systems",
          run_from: Date(2026, calendar.June, 1),
          run_to: Date(2027, calendar.January, 1),
          lanes: [
            view.EngineerLane(
              engineer_id: 1,
              name: "Priya Sharma",
              level: 5,
              cells: [
                view.Working(fraction: 0.5, over_allocated: True),
                view.OnLeave,
              ],
            ),
            view.EngineerLane(
              engineer_id: 2,
              name: "Marcus Chen",
              level: 4,
              cells: [
                view.OutsideRun,
                view.Idle,
              ],
            ),
          ],
          lines: [
            view.RequirementLine(kind: view.LevelLine(level: 3), gaps: [
              2.0,
              0.0,
            ]),
            view.RequirementLine(
              kind: view.CapabilityLine(
                capability_id: 1,
                name: "Payments Platform",
                target_level: 3,
              ),
              gaps: [1.5, 1.5],
            ),
          ],
          team: [
            view.FilledSeat(
              level: 3,
              engineer_id: 1,
              name: "Priya Sharma",
              fraction: 0.5,
            ),
            view.OpenSeat(level: 3, fraction: 1.0),
            view.OpenSeat(level: 3, fraction: 0.5),
          ],
          capabilities: [
            view.CapabilityCoverage(
              capability_id: 1,
              name: "Payments Platform",
              target_level: 3,
              team_proficiency: 3.5,
            ),
          ],
          annotation: Some("outside contract term"),
        ),
      ],
    )
  assert round_trip_schedule(schedule) == Ok(schedule)
}

pub fn preview_result_codec_round_trip_test() {
  let result =
    view.PreviewResult(
      schedule: view.Schedule(
        as_of: Date(2026, calendar.June, 15),
        weeks: [],
        projects: [],
      ),
      outcomes: [
        view.OperationApplied,
        view.OperationRejected(detail: "overlapping fact"),
      ],
    )
  let round_tripped =
    view.encode_preview_result(result)
    |> json.to_string
    |> json.parse(view.preview_result_decoder())
  assert round_tripped == Ok(result)
}

pub fn candidate_codec_round_trip_test() {
  let candidate =
    view.Candidate(
      engineer_id: 3,
      name: "Aisha Okafor",
      level: 6,
      proficiency: 2.9,
      free: 0.0,
      commitments: "Data Platform 100%",
    )
  let round_tripped =
    view.encode_candidate(candidate)
    |> json.to_string
    |> json.parse(view.candidate_decoder())
  assert round_tripped == Ok(candidate)
}
