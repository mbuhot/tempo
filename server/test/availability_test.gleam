import gleam/dynamic/decode
import gleam/list
import gleam/option.{None, Some}
import gleam/time/calendar.{type Date, August, Date, July, October}
import pog
import shared/availability/command as availability_command
import shared/command as gateway
import tempo/server/availability/sql as availability_sql
import tempo/server/command
import tempo/server/fact.{EngineerId, WorkDayCleared}
import tempo/server/operation
import tempo/server/repository
import test_pool

fn rolling_back(body: fn(pog.Connection) -> a) -> a {
  let assert Error(pog.TransactionRolledBack(value)) =
    pog.transaction(test_pool.db(), fn(conn) { Error(body(conn)) })
  value
}

fn insert_engineer(conn: pog.Connection) -> Int {
  let row = {
    use id <- decode.field(0, decode.int)
    decode.success(id)
  }
  let assert Ok(returned) =
    pog.query("INSERT INTO engineer DEFAULT VALUES RETURNING id")
    |> pog.returning(row)
    |> pog.execute(on: conn)
  let assert [id, ..] = returned.rows
  id
}

pub fn clearing_an_empty_weekday_succeeds_test() {
  use conn <- rolling_back()
  let engineer_id = insert_engineer(conn)
  let outcome =
    repository.write(
      conn,
      1,
      WorkDayCleared(
        engineer_id: EngineerId(engineer_id),
        weekday: 4,
        from: Date(2026, July, 1),
      ),
    )
  assert outcome == Ok(Nil)
}

fn full_week(
  monday_hours: #(String, String),
  working_days: List(Int),
) -> List(availability_command.DayHours) {
  [0, 1, 2, 3, 4, 5, 6]
  |> list.map(fn(weekday) {
    case list.contains(working_days, weekday) {
      False -> availability_command.DayHours(weekday, None)
      True ->
        availability_command.DayHours(weekday, case weekday {
          0 -> Some(monday_hours)
          _ -> Some(#("09:00", "17:00"))
        })
    }
  })
}

fn monday_starts_at(
  conn: pog.Connection,
  engineer_id: Int,
  as_of: Date,
) -> String {
  let assert Ok(returned) =
    availability_sql.work_schedule_asof(conn, engineer_id, as_of)
  let assert Ok(monday) =
    returned.rows |> list.find(fn(row) { row.weekday == 0 })
  monday.starts
}

pub fn set_work_schedule_records_the_working_days_test() {
  rolling_back(fn(conn) {
    let engineer_id = insert_engineer(conn)
    let effective = Date(2026, July, 6)
    let assert Ok(_) =
      command.dispatch_in(
        conn,
        "tester",
        gateway.AvailabilityCommand(availability_command.SetWorkSchedule(
          engineer_id:,
          effective:,
          days: full_week(#("09:00", "17:00"), [0, 1, 2, 3]),
        )),
      )
    let assert Ok(returned) =
      availability_sql.work_schedule_asof(conn, engineer_id, effective)
    assert list.length(returned.rows) == 4
    assert list.all(returned.rows, fn(row) { row.starts == "09:00" })
  })
}

pub fn resetting_from_a_later_date_opens_a_new_era_test() {
  rolling_back(fn(conn) {
    let engineer_id = insert_engineer(conn)
    let earlier = Date(2026, July, 6)
    let later = Date(2026, July, 20)
    let assert Ok(_) =
      command.dispatch_in(
        conn,
        "tester",
        gateway.AvailabilityCommand(availability_command.SetWorkSchedule(
          engineer_id:,
          effective: earlier,
          days: full_week(#("09:00", "17:00"), [0, 1, 2, 3, 4]),
        )),
      )
    let assert Ok(_) =
      command.dispatch_in(
        conn,
        "tester",
        gateway.AvailabilityCommand(availability_command.SetWorkSchedule(
          engineer_id:,
          effective: later,
          days: full_week(#("10:00", "16:00"), [0, 1, 2, 3, 4]),
        )),
      )
    assert monday_starts_at(conn, engineer_id, earlier) == "09:00"
    assert monday_starts_at(conn, engineer_id, later) == "10:00"
  })
}

pub fn set_work_schedule_rejects_a_malformed_grid_test() {
  let outcome =
    rolling_back(fn(conn) {
      let engineer_id = insert_engineer(conn)
      command.dispatch_in(
        conn,
        "tester",
        gateway.AvailabilityCommand(
          availability_command.SetWorkSchedule(
            engineer_id:,
            effective: Date(2026, July, 6),
            days: [
              availability_command.DayHours(0, Some(#("09:00", "17:00"))),
              availability_command.DayHours(1, Some(#("09:00", "17:00"))),
              availability_command.DayHours(2, Some(#("09:00", "17:00"))),
              availability_command.DayHours(3, Some(#("09:00", "17:00"))),
              availability_command.DayHours(4, Some(#("09:00", "17:00"))),
              availability_command.DayHours(5, None),
            ],
          ),
        ),
      )
    })
  assert outcome == Error(operation.InvalidValue)
}

pub fn set_work_schedule_rejects_a_bad_time_test() {
  let outcome =
    rolling_back(fn(conn) {
      let engineer_id = insert_engineer(conn)
      command.dispatch_in(
        conn,
        "tester",
        gateway.AvailabilityCommand(availability_command.SetWorkSchedule(
          engineer_id:,
          effective: Date(2026, July, 6),
          days: full_week(#("25:00", "17:00"), [0, 1, 2, 3, 4]),
        )),
      )
    })
  assert outcome == Error(operation.InvalidValue)
}

fn focus_block_id_for(conn: pog.Connection, title: String) -> Int {
  let row = {
    use id <- decode.field(0, decode.int)
    decode.success(id)
  }
  let assert Ok(returned) =
    pog.query("SELECT id FROM focus_block WHERE title = $1")
    |> pog.parameter(pog.text(title))
    |> pog.returning(row)
    |> pog.execute(on: conn)
  let assert [id] = returned.rows
  id
}

fn focus_block_count(conn: pog.Connection, focus_block_id: Int) -> Int {
  let row = {
    use count <- decode.field(0, decode.int)
    decode.success(count)
  }
  let assert Ok(returned) =
    pog.query("SELECT count(*) FROM focus_block WHERE id = $1")
    |> pog.parameter(pog.int(focus_block_id))
    |> pog.returning(row)
    |> pog.execute(on: conn)
  let assert [count] = returned.rows
  count
}

fn focus_block_local_starts_at(
  conn: pog.Connection,
  focus_block_id: Int,
  timezone: String,
) -> String {
  let row = {
    use starts_at <- decode.field(0, decode.string)
    decode.success(starts_at)
  }
  let assert Ok(returned) =
    pog.query(
      "SELECT to_char(lower(busy_at) AT TIME ZONE $2, 'HH24:MI') FROM focus_block WHERE id = $1",
    )
    |> pog.parameter(pog.int(focus_block_id))
    |> pog.parameter(pog.text(timezone))
    |> pog.returning(row)
    |> pog.execute(on: conn)
  let assert [starts_at] = returned.rows
  starts_at
}

fn focus_block_audit_id(conn: pog.Connection, focus_block_id: Int) -> Int {
  let row = {
    use audit_id <- decode.field(0, decode.int)
    decode.success(audit_id)
  }
  let assert Ok(returned) =
    pog.query("SELECT audit_id FROM focus_block WHERE id = $1")
    |> pog.parameter(pog.int(focus_block_id))
    |> pog.returning(row)
    |> pog.execute(on: conn)
  let assert [audit_id] = returned.rows
  audit_id
}

pub fn add_focus_block_records_the_composed_range_test() {
  rolling_back(fn(conn) {
    let engineer_id = insert_engineer(conn)
    let assert Ok(_) =
      command.dispatch_in(
        conn,
        "tester",
        gateway.AvailabilityCommand(availability_command.AddFocusBlock(
          engineer_id:,
          date: Date(2026, July, 10),
          starts_at: "14:00",
          duration_minutes: 90,
          timezone: "Europe/London",
          title: "Deep work",
        )),
      )
    let focus_block_id = focus_block_id_for(conn, "Deep work")
    assert focus_block_local_starts_at(conn, focus_block_id, "Europe/London")
      == "14:00"
    assert focus_block_audit_id(conn, focus_block_id) > 0
  })
}

pub fn add_focus_block_rejects_an_unknown_timezone_test() {
  let outcome =
    rolling_back(fn(conn) {
      let engineer_id = insert_engineer(conn)
      command.dispatch_in(
        conn,
        "tester",
        gateway.AvailabilityCommand(availability_command.AddFocusBlock(
          engineer_id:,
          date: Date(2026, July, 10),
          starts_at: "14:00",
          duration_minutes: 90,
          timezone: "Mars/Olympus_Mons",
          title: "Broken zone",
        )),
      )
    })
  assert outcome == Error(operation.InvalidValue)
}

pub fn remove_focus_block_deletes_the_row_test() {
  rolling_back(fn(conn) {
    let engineer_id = insert_engineer(conn)
    let assert Ok(_) =
      command.dispatch_in(
        conn,
        "tester",
        gateway.AvailabilityCommand(availability_command.AddFocusBlock(
          engineer_id:,
          date: Date(2026, July, 10),
          starts_at: "14:00",
          duration_minutes: 90,
          timezone: "Europe/London",
          title: "Removable",
        )),
      )
    let focus_block_id = focus_block_id_for(conn, "Removable")
    let assert Ok(_) =
      command.dispatch_in(
        conn,
        "tester",
        gateway.AvailabilityCommand(availability_command.RemoveFocusBlock(
          engineer_id:,
          focus_block_id:,
        )),
      )
    assert focus_block_count(conn, focus_block_id) == 0
  })
}

pub fn remove_focus_block_with_the_wrong_engineer_is_rejected_test() {
  let outcome =
    rolling_back(fn(conn) {
      let engineer_id = insert_engineer(conn)
      let other_engineer_id = insert_engineer(conn)
      let assert Ok(_) =
        command.dispatch_in(
          conn,
          "tester",
          gateway.AvailabilityCommand(availability_command.AddFocusBlock(
            engineer_id:,
            date: Date(2026, July, 10),
            starts_at: "14:00",
            duration_minutes: 90,
            timezone: "Europe/London",
            title: "Someone else's block",
          )),
        )
      let focus_block_id = focus_block_id_for(conn, "Someone else's block")
      command.dispatch_in(
        conn,
        "tester",
        gateway.AvailabilityCommand(availability_command.RemoveFocusBlock(
          engineer_id: other_engineer_id,
          focus_block_id:,
        )),
      )
    })
  assert outcome == Error(operation.NoSuchVersion)
}

fn holiday_name(
  conn: pog.Connection,
  country: String,
  region: String,
  holiday_on: Date,
) -> String {
  let row = {
    use name <- decode.field(0, decode.string)
    decode.success(name)
  }
  let assert Ok(returned) =
    pog.query(
      "SELECT name FROM holiday WHERE country = $1 AND region = $2 AND holiday_on = $3::date",
    )
    |> pog.parameter(pog.text(country))
    |> pog.parameter(pog.text(region))
    |> pog.parameter(pog.calendar_date(holiday_on))
    |> pog.returning(row)
    |> pog.execute(on: conn)
  let assert [name] = returned.rows
  name
}

pub fn import_holidays_upserts_rows_and_rejects_an_unknown_region_test() {
  rolling_back(fn(conn) {
    let assert Ok(_) =
      command.dispatch_in(
        conn,
        "tester",
        gateway.AvailabilityCommand(
          availability_command.ImportHolidays(rows: [
            availability_command.HolidayRow(
              "AU",
              "AU-NSW",
              Date(2026, October, 5),
              "Labour Day",
            ),
            availability_command.HolidayRow(
              "GB",
              "",
              Date(2026, August, 31),
              "Summer Bank Holiday",
            ),
          ]),
        ),
      )
    assert holiday_name(conn, "AU", "AU-NSW", Date(2026, October, 5))
      == "Labour Day"
    assert holiday_name(conn, "GB", "", Date(2026, August, 31))
      == "Summer Bank Holiday"

    let assert Ok(_) =
      command.dispatch_in(
        conn,
        "tester",
        gateway.AvailabilityCommand(
          availability_command.ImportHolidays(rows: [
            availability_command.HolidayRow(
              "AU",
              "AU-NSW",
              Date(2026, October, 5),
              "Labour Day (renamed)",
            ),
          ]),
        ),
      )
    assert holiday_name(conn, "AU", "AU-NSW", Date(2026, October, 5))
      == "Labour Day (renamed)"

    let outcome =
      command.dispatch_in(
        conn,
        "tester",
        gateway.AvailabilityCommand(
          availability_command.ImportHolidays(rows: [
            availability_command.HolidayRow(
              "FR",
              "",
              Date(2026, July, 14),
              "Bastille Day",
            ),
          ]),
        ),
      )
    assert outcome == Error(operation.InvalidValue)
  })
}
