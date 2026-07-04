//// The schedule read model: assemble the weekly allocation timeline — lanes,
//// requirement gap lines, team seats, capability coverage — from five SQL
//// queries run on the CALLER's connection, so the preview executor can evaluate
//// the same read inside its transaction (reads on a tx connection stay serial;
//// the async fan-out helper is pool-only).

import gleam/dict.{type Dict}
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{None}
import gleam/order
import gleam/result
import gleam/string
import gleam/time/calendar.{type Date}
import pog
import shared/schedule/view.{
  type CellState, type EngineerLane, type ProjectSchedule, type RequirementLine,
  type Schedule, type Seat, CapabilityCoverage, CapabilityLine, EngineerLane,
  FilledSeat, Idle, LevelLine, OnLeave, OpenSeat, OutsideRun, ProjectSchedule,
  RequirementLine, Schedule, Working,
} as shared_schedule
import tempo/server/schedule/sql

pub fn timeline(
  db: pog.Connection,
  as_of: Date,
) -> Result(Schedule, pog.QueryError) {
  use weeks <- result.try(sql.schedule_weeks(db, as_of))
  use projects <- result.try(sql.schedule_projects(db, as_of))
  use lanes <- result.try(sql.schedule_lanes(db, as_of))
  use totals <- result.try(sql.schedule_totals(db, as_of))
  use level_gaps <- result.try(sql.schedule_level_gaps(db, as_of))
  use capability_gaps <- result.map(sql.schedule_capability_gaps(db, as_of))
  assemble(
    as_of,
    list.map(weeks.rows, fn(row) { row.week }),
    projects.rows,
    lanes.rows,
    totals.rows,
    level_gaps.rows,
    capability_gaps.rows,
  )
}

fn before(a: Date, b: Date) -> Bool {
  calendar.naive_date_compare(a, b) == order.Lt
}

fn at_or_after(a: Date, b: Date) -> Bool {
  calendar.naive_date_compare(a, b) != order.Lt
}

fn assemble(
  as_of: Date,
  weeks: List(Date),
  projects: List(sql.ScheduleProjectsRow),
  lane_rows: List(sql.ScheduleLanesRow),
  total_rows: List(sql.ScheduleTotalsRow),
  level_gap_rows: List(sql.ScheduleLevelGapsRow),
  capability_gap_rows: List(sql.ScheduleCapabilityGapsRow),
) -> Schedule {
  let totals = totals_by_engineer_week(total_rows)
  let projects =
    list.map(projects, fn(project) {
      assemble_project(
        project,
        weeks,
        totals,
        lane_rows,
        level_gap_rows,
        capability_gap_rows,
      )
    })
  Schedule(as_of:, weeks:, projects:)
}

fn totals_by_engineer_week(
  rows: List(sql.ScheduleTotalsRow),
) -> Dict(#(Int, Date), Float) {
  list.fold(rows, dict.new(), fn(acc, row) {
    dict.insert(acc, #(row.engineer_id, row.week), row.total)
  })
}

fn assemble_project(
  project: sql.ScheduleProjectsRow,
  weeks: List(Date),
  totals: Dict(#(Int, Date), Float),
  lane_rows: List(sql.ScheduleLanesRow),
  level_gap_rows: List(sql.ScheduleLevelGapsRow),
  capability_gap_rows: List(sql.ScheduleCapabilityGapsRow),
) -> ProjectSchedule {
  let project_lane_rows =
    list.filter(lane_rows, fn(row) { row.project_id == project.project_id })
  let project_level_gap_rows =
    list.filter(level_gap_rows, fn(row) { row.project_id == project.project_id })
  let project_capability_gap_rows =
    list.filter(capability_gap_rows, fn(row) {
      row.project_id == project.project_id
    })

  let lanes = lanes_for(project, weeks, totals, project_lane_rows)
  let level_lines = level_lines_for(weeks, project_level_gap_rows)
  let capability_lines =
    capability_lines_for(weeks, project_capability_gap_rows)
  let lines = list.append(level_lines, capability_lines)
  let team = seats_for(project_level_gap_rows, lanes)
  let capabilities = coverage_for(project_capability_gap_rows)

  ProjectSchedule(
    project_id: project.project_id,
    title: project.title,
    client: project.client,
    run_from: project.run_from,
    run_to: project.run_to,
    lanes:,
    lines:,
    team:,
    capabilities:,
    annotation: None,
  )
}

fn lanes_for(
  project: sql.ScheduleProjectsRow,
  weeks: List(Date),
  totals: Dict(#(Int, Date), Float),
  lane_rows: List(sql.ScheduleLanesRow),
) -> List(EngineerLane) {
  let by_engineer =
    list.fold(lane_rows, dict.new(), fn(acc, row) {
      dict.upsert(acc, row.engineer_id, fn(existing) {
        case existing {
          option.Some(rows) -> list.append(rows, [row])
          option.None -> [row]
        }
      })
    })
  dict.values(by_engineer)
  |> list.map(fn(rows) {
    let assert [first, ..] = rows
    let cells =
      list.map(weeks, fn(week) { cell_for(project, week, first, rows, totals) })
    EngineerLane(
      engineer_id: first.engineer_id,
      name: first.name,
      level: first.level,
      cells:,
    )
  })
  |> list.sort(fn(left, right) { string_compare(left.name, right.name) })
}

fn string_compare(left: String, right: String) -> order.Order {
  string.compare(left, right)
}

fn cell_for(
  project: sql.ScheduleProjectsRow,
  week: Date,
  lane: sql.ScheduleLanesRow,
  rows: List(sql.ScheduleLanesRow),
  totals: Dict(#(Int, Date), Float),
) -> CellState {
  case before(week, project.run_from), at_or_after(week, project.run_to) {
    True, _ -> OutsideRun
    _, True -> OutsideRun
    _, _ ->
      case list.find(rows, fn(row) { row.week == week }) {
        Error(Nil) -> Idle
        Ok(row) ->
          case row.on_leave {
            True -> OnLeave
            False -> {
              let total =
                dict.get(totals, #(lane.engineer_id, week))
                |> result.unwrap(row.fraction)
              Working(fraction: row.fraction, over_allocated: total >. 1.0)
            }
          }
      }
  }
}

fn level_lines_for(
  weeks: List(Date),
  rows: List(sql.ScheduleLevelGapsRow),
) -> List(RequirementLine) {
  let by_level =
    list.fold(rows, dict.new(), fn(acc, row) {
      dict.upsert(acc, row.level, fn(existing) {
        case existing {
          option.Some(existing_rows) -> list.append(existing_rows, [row])
          option.None -> [row]
        }
      })
    })
  dict.to_list(by_level)
  |> list.sort(fn(left, right) { int.compare(left.0, right.0) })
  |> list.map(fn(entry) {
    let #(level, level_rows) = entry
    let gaps =
      list.map(weeks, fn(week) {
        case list.find(level_rows, fn(row) { row.week == week }) {
          Error(Nil) -> 0.0
          Ok(row) -> float.max(0.0, row.quantity -. row.covered)
        }
      })
    RequirementLine(kind: LevelLine(level:), gaps:)
  })
  |> list.filter(fn(line) { list.any(line.gaps, fn(gap) { gap >. 0.0 }) })
}

fn capability_lines_for(
  weeks: List(Date),
  rows: List(sql.ScheduleCapabilityGapsRow),
) -> List(RequirementLine) {
  let by_capability =
    list.fold(rows, dict.new(), fn(acc, row) {
      dict.upsert(acc, row.capability_id, fn(existing) {
        case existing {
          option.Some(existing_rows) -> list.append(existing_rows, [row])
          option.None -> [row]
        }
      })
    })
  dict.to_list(by_capability)
  |> list.sort(fn(left, right) { int.compare(left.0, right.0) })
  |> list.map(fn(entry) {
    let #(capability_id, capability_rows) = entry
    let assert [first, ..] = capability_rows
    let gaps =
      list.map(weeks, fn(week) {
        case list.find(capability_rows, fn(row) { row.week == week }) {
          Error(Nil) -> 0.0
          Ok(row) -> float.max(0.0, row.quantity -. row.covered)
        }
      })
    RequirementLine(
      kind: CapabilityLine(
        capability_id:,
        name: first.name,
        target_level: first.target_level,
      ),
      gaps:,
    )
  })
  |> list.filter(fn(line) { list.any(line.gaps, fn(gap) { gap >. 0.0 }) })
}

fn seats_for(
  level_gap_rows: List(sql.ScheduleLevelGapsRow),
  lanes: List(EngineerLane),
) -> List(Seat) {
  let by_level =
    list.fold(level_gap_rows, dict.new(), fn(acc, row) {
      case dict.get(acc, row.level) {
        Ok(_) -> acc
        Error(Nil) -> dict.insert(acc, row.level, row.quantity)
      }
    })
  dict.to_list(by_level)
  |> list.sort(fn(left, right) { int.compare(left.0, right.0) })
  |> list.flat_map(fn(entry) {
    let #(level, quantity) = entry
    seats_for_level(level, quantity, lanes)
  })
}

fn seats_for_level(
  level: Int,
  quantity: Float,
  lanes: List(EngineerLane),
) -> List(Seat) {
  let qualifying =
    lanes
    |> list.filter(fn(lane) { lane.level >= level })
    |> list.map(fn(lane) { #(lane, lane_fraction(lane)) })
    |> list.sort(fn(left, right) {
      case float.compare(right.1, left.1) {
        order.Eq -> string_compare(left.0.name, right.0.name)
        other -> other
      }
    })

  let #(seats, remaining) =
    list.fold(qualifying, #([], quantity), fn(acc, entry) {
      let #(seats, remaining) = acc
      let #(lane, fraction) = entry
      case remaining >. 0.0 {
        False -> #(seats, remaining)
        True -> {
          let seat_fraction = float.min(fraction, remaining)
          #(
            list.append(seats, [
              FilledSeat(
                level:,
                engineer_id: lane.engineer_id,
                name: lane.name,
                fraction: seat_fraction,
              ),
            ]),
            remaining -. seat_fraction,
          )
        }
      }
    })

  let open_seats = open_seats_for(level, remaining)
  list.append(seats, open_seats)
}

fn open_seats_for(level: Int, remaining: Float) -> List(Seat) {
  case remaining >. 0.0 {
    False -> []
    True -> {
      let fraction = float.min(1.0, remaining)
      [
        OpenSeat(level:, fraction:),
        ..open_seats_for(level, remaining -. fraction)
      ]
    }
  }
}

fn lane_fraction(lane: EngineerLane) -> Float {
  lane.cells
  |> list.filter_map(fn(cell) {
    case cell {
      Working(fraction:, ..) -> Ok(fraction)
      _ -> Error(Nil)
    }
  })
  |> list.first
  |> result.unwrap(0.0)
}

fn coverage_for(
  rows: List(sql.ScheduleCapabilityGapsRow),
) -> List(shared_schedule.CapabilityCoverage) {
  let by_capability =
    list.fold(rows, dict.new(), fn(acc, row) {
      dict.upsert(acc, row.capability_id, fn(existing) {
        case existing {
          option.Some(existing_rows) -> list.append(existing_rows, [row])
          option.None -> [row]
        }
      })
    })
  dict.to_list(by_capability)
  |> list.sort(fn(left, right) { int.compare(left.0, right.0) })
  |> list.map(fn(entry) {
    let #(capability_id, capability_rows) = entry
    let assert [first, ..] = capability_rows
    let best =
      list.fold(capability_rows, 0.0, fn(acc, row) { float.max(acc, row.best) })
    CapabilityCoverage(
      capability_id:,
      name: first.name,
      target_level: first.target_level,
      team_proficiency: best,
    )
  })
}
