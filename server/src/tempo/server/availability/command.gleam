//// Write handler for availability. set_work_schedule validates the 7-day grid and fans
//// out one fact per weekday; add_focus_block validates the TZID; import_holidays checks
//// every region against the reference table before upserting.

import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/order
import gleam/result
import gleam/string
import gleam/time/calendar.{type Date}
import pog
import shared/availability/command.{
  type AvailabilityCommand, type DayHours, type HolidayRow, AddFocusBlock,
  ImportHolidays, RemoveFocusBlock, SetWorkSchedule,
}
import shared/command as gateway
import tempo/server/availability/sql as availability_sql
import tempo/server/fact.{
  type Recorded, EngineerId, FocusBlockAdded, FocusBlockRemoved, HolidayImported,
  Recorded, WorkDayCleared, WorkHoursSet,
}
import tempo/server/operation.{type OperationError, Event}

/// Route an availability command to its operation. Exhaustive over
/// `AvailabilityCommand`.
pub fn route(
  conn: pog.Connection,
  command: AvailabilityCommand,
) -> Result(Recorded, OperationError) {
  case command {
    SetWorkSchedule(engineer_id:, effective:, days:) ->
      set_work_schedule(command, engineer_id:, effective:, days:)
    AddFocusBlock(
      engineer_id:,
      date:,
      starts_at:,
      duration_minutes:,
      timezone:,
      title:,
    ) ->
      add_focus_block(
        conn,
        command,
        engineer_id:,
        date:,
        starts_at:,
        duration_minutes:,
        timezone:,
        title:,
      )
    RemoveFocusBlock(engineer_id:, focus_block_id:) ->
      Ok(remove_focus_block(command, engineer_id:, focus_block_id:))
    ImportHolidays(rows:) -> import_holidays(conn, command, rows)
  }
}

fn valid_time(raw: String) -> Bool {
  case string.split(raw, ":") {
    [hour_text, minute_text] ->
      case int.parse(hour_text), int.parse(minute_text) {
        Ok(hour), Ok(minute) ->
          string.length(hour_text) == 2
          && string.length(minute_text) == 2
          && hour >= 0
          && hour <= 23
          && minute >= 0
          && minute <= 59
        _, _ -> False
      }
    _ -> False
  }
}

fn day_valid(day: DayHours) -> Bool {
  case day.hours {
    None -> True
    Some(#(starts, ends)) ->
      valid_time(starts)
      && valid_time(ends)
      && string.compare(starts, ends) == order.Lt
  }
}

fn week_valid(days: List(DayHours)) -> Bool {
  let weekdays =
    days |> list.map(fn(day) { day.weekday }) |> list.sort(int.compare)
  weekdays == [0, 1, 2, 3, 4, 5, 6] && list.all(days, day_valid)
}

fn set_work_schedule(
  command: AvailabilityCommand,
  engineer_id engineer_id: Int,
  effective effective: Date,
  days days: List(DayHours),
) -> Result(Recorded, OperationError) {
  case week_valid(days) {
    False -> Error(operation.InvalidValue)
    True -> {
      let facts =
        list.map(days, fn(day) {
          case day.hours {
            Some(#(starts, ends)) ->
              WorkHoursSet(
                engineer_id: EngineerId(engineer_id),
                weekday: day.weekday,
                from: effective,
                starts:,
                ends:,
              )
            None ->
              WorkDayCleared(
                engineer_id: EngineerId(engineer_id),
                weekday: day.weekday,
                from: effective,
              )
          }
        })
      Ok(Recorded(
        entry: Event(
          operation: "set_work_schedule",
          summary: "Set weekly hours for engineer "
            <> int.to_string(engineer_id)
            <> " from "
            <> operation.iso(effective),
          payload: gateway.encode_command(gateway.AvailabilityCommand(command)),
        ),
        facts:,
      ))
    }
  }
}

fn add_focus_block(
  conn: pog.Connection,
  command: AvailabilityCommand,
  engineer_id engineer_id: Int,
  date date: Date,
  starts_at starts_at: String,
  duration_minutes duration_minutes: Int,
  timezone timezone: String,
  title title: String,
) -> Result(Recorded, OperationError) {
  use valid <- operation.try(availability_sql.timezone_valid(conn, timezone))
  let assert [check] = valid.rows
  case check.valid && valid_time(starts_at) && duration_minutes > 0 {
    False -> Error(operation.InvalidValue)
    True ->
      Ok(
        Recorded(
          entry: Event(
            operation: "add_focus_block",
            summary: "Added focus block \""
              <> title
              <> "\" for engineer "
              <> int.to_string(engineer_id)
              <> " on "
              <> operation.iso(date),
            payload: gateway.encode_command(gateway.AvailabilityCommand(command)),
          ),
          facts: [
            FocusBlockAdded(
              engineer_id: EngineerId(engineer_id),
              date:,
              starts_at:,
              duration_minutes:,
              timezone:,
              title:,
            ),
          ],
        ),
      )
  }
}

fn remove_focus_block(
  command: AvailabilityCommand,
  engineer_id engineer_id: Int,
  focus_block_id focus_block_id: Int,
) -> Recorded {
  Recorded(
    entry: Event(
      operation: "remove_focus_block",
      summary: "Removed focus block "
        <> int.to_string(focus_block_id)
        <> " for engineer "
        <> int.to_string(engineer_id),
      payload: gateway.encode_command(gateway.AvailabilityCommand(command)),
    ),
    facts: [
      FocusBlockRemoved(engineer_id: EngineerId(engineer_id), focus_block_id:),
    ],
  )
}

fn import_holidays(
  conn: pog.Connection,
  command: AvailabilityCommand,
  rows: List(HolidayRow),
) -> Result(Recorded, OperationError) {
  case rows {
    [] -> Error(operation.InvalidValue)
    _ -> {
      use _ <- result.try(ensure_regions(conn, rows))
      Ok(Recorded(
        entry: Event(
          operation: "import_holidays",
          summary: "Imported "
            <> int.to_string(list.length(rows))
            <> " public holidays",
          payload: gateway.encode_command(gateway.AvailabilityCommand(command)),
        ),
        facts: list.map(rows, fn(row) {
          HolidayImported(
            country: row.country,
            region: row.region,
            holiday_on: row.holiday_on,
            name: row.name,
          )
        }),
      ))
    }
  }
}

fn ensure_regions(
  conn: pog.Connection,
  rows: List(HolidayRow),
) -> Result(Nil, OperationError) {
  case rows {
    [] -> Ok(Nil)
    [row, ..rest] -> {
      use known <- operation.try(availability_sql.holiday_region_exists(
        conn,
        row.country,
        row.region,
      ))
      let assert [check] = known.rows
      case check.known {
        True -> ensure_regions(conn, rest)
        False -> Error(operation.InvalidValue)
      }
    }
  }
}
