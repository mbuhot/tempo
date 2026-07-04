//// Reads for engineer location: the as-of listing (every engineer + their location on a
//// date, or none) and one engineer's full history. The listing joins a roster query and
//// an as-of-locations query in Gleam (not a LEFT JOIN) — `sql.engineer_roster` reads
//// `engineer_current` directly, so Squirrel cannot prove its columns NOT NULL, and rows
//// with either field absent are dropped as they can never actually occur.

import gleam/dict
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/time/calendar.{type Date}
import pog
import shared/location/view.{
  type EngineerLocation, type LocationRecord, EngineerLocation, LocationRecord,
}
import tempo/server/context.{type Context}
import tempo/server/location/sql

/// Every engineer and their location as-of `as_of` (`None` when unset on that date).
pub fn listing(
  context: Context,
  as_of: Date,
) -> Result(List(EngineerLocation), pog.QueryError) {
  use roster <- result.try(sql.engineer_roster(context.db))
  use located <- result.map(sql.engineer_locations_asof(context.db, as_of))
  let by_engineer =
    located.rows
    |> list.map(fn(row) { #(row.engineer_id, asof_row_to_record(row)) })
    |> dict.from_list
  roster.rows
  |> list.filter_map(roster_row_to_engineer)
  |> list.map(fn(engineer) {
    let #(engineer_id, name) = engineer
    EngineerLocation(
      engineer_id:,
      name:,
      location: dict.get(by_engineer, engineer_id) |> option.from_result,
    )
  })
}

/// One engineer's full location history, oldest span first, each span's UTC offset
/// computed as-of `as_of`.
pub fn history(
  context: Context,
  engineer_id: Int,
  as_of: Date,
) -> Result(List(LocationRecord), pog.QueryError) {
  use returned <- result.map(sql.engineer_location_history(
    context.db,
    engineer_id,
    as_of,
  ))
  list.map(returned.rows, history_row_to_record)
}

fn roster_row_to_engineer(
  row: sql.EngineerRosterRow,
) -> Result(#(Int, String), Nil) {
  case row.engineer_id, row.name {
    Some(engineer_id), Some(name) -> Ok(#(engineer_id, name))
    _, _ -> Error(Nil)
  }
}

fn asof_row_to_record(row: sql.EngineerLocationsAsofRow) -> LocationRecord {
  LocationRecord(
    country: row.country,
    region: row.region,
    timezone: row.timezone,
    valid_from: row.valid_from,
    valid_to: open_end(row.ongoing, row.valid_to),
    utc_offset_minutes: row.utc_offset_minutes,
  )
}

fn history_row_to_record(
  row: sql.EngineerLocationHistoryRow,
) -> LocationRecord {
  LocationRecord(
    country: row.country,
    region: row.region,
    timezone: row.timezone,
    valid_from: row.valid_from,
    valid_to: open_end(row.ongoing, row.valid_to),
    utc_offset_minutes: row.utc_offset_minutes,
  )
}

/// An open (`ongoing`) span has no end date; otherwise its coalesced upper bound.
fn open_end(ongoing: Bool, valid_to: Date) -> Option(Date) {
  case ongoing {
    True -> None
    False -> Some(valid_to)
  }
}
