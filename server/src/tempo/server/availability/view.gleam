//// Reads for availability: one engineer's as-of weekly hours grid paired with
//// their upcoming focus blocks and holidays, and the standalone holidays
//// listing across every seeded region. The weekly grid folds `work_schedule_asof`
//// rows (present only for weekdays with hours set) into all 7 weekdays 0–6,
//// filling the gaps with an empty `DaySlot`.

import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{Some}
import gleam/result
import gleam/time/calendar.{type Date}
import pog
import shared/availability/view.{
  type AvailabilityRecord, type DaySlot, type HolidayListing, AvailabilityRecord,
  DaySlot, EngineerHoliday, FocusBlockRecord, HolidayListing,
}
import tempo/server/availability/sql
import tempo/server/context.{type Context}

/// The as-of weekly hours grid, upcoming focus blocks, and upcoming holidays
/// for one engineer.
pub fn availability(
  context: Context,
  engineer_id: Int,
  as_of: Date,
) -> Result(AvailabilityRecord, pog.QueryError) {
  use schedule <- result.try(sql.work_schedule_asof(
    context.db,
    engineer_id,
    as_of,
  ))
  use focus_blocks <- result.try(sql.focus_blocks_upcoming(
    context.db,
    engineer_id,
    as_of,
  ))
  use holidays <- result.map(sql.holidays_for_engineer(
    context.db,
    engineer_id,
    as_of,
  ))
  AvailabilityRecord(
    week: week_of(schedule.rows),
    focus_blocks: list.map(focus_blocks.rows, focus_block_row_to_record),
    holidays: list.map(holidays.rows, holiday_row_to_record),
  )
}

/// Every holiday on/after `as_of` across all seeded regions, with region names.
pub fn holidays(
  context: Context,
  as_of: Date,
) -> Result(List(HolidayListing), pog.QueryError) {
  use rows <- result.map(sql.holidays_upcoming(context.db, as_of))
  list.map(rows.rows, holiday_listing_row_to_record)
}

fn week_of(rows: List(sql.WorkScheduleAsofRow)) -> List(DaySlot) {
  let hours_by_weekday = group_by_weekday(rows)
  list.map([0, 1, 2, 3, 4, 5, 6], fn(weekday) {
    case dict.get(hours_by_weekday, weekday) {
      Ok(row) ->
        DaySlot(weekday:, starts: Some(row.starts), ends: Some(row.ends))
      Error(Nil) -> DaySlot(weekday:, starts: option.None, ends: option.None)
    }
  })
}

fn group_by_weekday(
  rows: List(sql.WorkScheduleAsofRow),
) -> Dict(Int, sql.WorkScheduleAsofRow) {
  list.fold(rows, dict.new(), fn(by_weekday, row) {
    dict.insert(by_weekday, row.weekday, row)
  })
}

fn focus_block_row_to_record(
  row: sql.FocusBlocksUpcomingRow,
) -> view.FocusBlockRecord {
  FocusBlockRecord(
    id: row.id,
    title: row.title,
    starts_at: row.starts_at,
    ends_at: row.ends_at,
    offset_minutes: row.offset_minutes,
  )
}

fn holiday_row_to_record(
  row: sql.HolidaysForEngineerRow,
) -> view.EngineerHoliday {
  EngineerHoliday(holiday_on: row.holiday_on, name: row.name)
}

fn holiday_listing_row_to_record(
  row: sql.HolidaysUpcomingRow,
) -> HolidayListing {
  HolidayListing(
    country: row.country,
    region: row.region,
    region_name: row.region_name,
    holiday_on: row.holiday_on,
    name: row.name,
  )
}
