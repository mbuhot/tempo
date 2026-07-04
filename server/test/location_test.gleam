import gleam/dynamic/decode
import gleam/list
import gleam/option.{None, Some}
import gleam/time/calendar.{type Date, Date, July, June}
import pog
import shared/command as gateway
import shared/location/command as location_command
import shared/location/view.{type EngineerLocation, LocationRecord}
import tempo/server/command
import tempo/server/location/view as location_view
import tempo/server/operation
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

fn current_timezone(
  conn: pog.Connection,
  engineer_id: Int,
  as_of: Date,
) -> String {
  let row = {
    use tz <- decode.field(0, decode.string)
    decode.success(tz)
  }
  let assert Ok(returned) =
    pog.query(
      "SELECT timezone FROM engineer_location WHERE engineer_id = $1 AND located_during @> $2::date",
    )
    |> pog.parameter(pog.int(engineer_id))
    |> pog.parameter(pog.calendar_date(as_of))
    |> pog.returning(row)
    |> pog.execute(on: conn)
  let assert [tz] = returned.rows
  tz
}

pub fn set_location_records_a_dated_fact_test() {
  let tz =
    rolling_back(fn(conn) {
      let engineer_id = insert_engineer(conn)
      let assert Ok(_) =
        command.dispatch_in(
          conn,
          "tester",
          gateway.LocationCommand(location_command.SetEngineerLocation(
            engineer_id:,
            country: "GB",
            region: Some("GB-LND"),
            timezone: "Europe/London",
            effective: Date(2026, June, 1),
          )),
        )
      current_timezone(conn, engineer_id, Date(2026, July, 1))
    })
  assert tz == "Europe/London"
}

pub fn set_location_rejects_an_unknown_timezone_test() {
  let outcome =
    rolling_back(fn(conn) {
      let engineer_id = insert_engineer(conn)
      command.dispatch_in(
        conn,
        "tester",
        gateway.LocationCommand(location_command.SetEngineerLocation(
          engineer_id:,
          country: "GB",
          region: None,
          timezone: "Mars/Olympus_Mons",
          effective: Date(2026, June, 1),
        )),
      )
    })
  assert outcome == Error(operation.InvalidValue)
}

fn priya(entries: List(EngineerLocation)) -> EngineerLocation {
  let assert Ok(entry) = list.find(entries, fn(e) { e.name == "Priya Sharma" })
  entry
}

pub fn listing_resolves_timezone_as_of_the_date_test() {
  let assert Ok(before) =
    location_view.listing(test_pool.ctx(), Date(2026, June, 15))
  let assert Ok(after) =
    location_view.listing(test_pool.ctx(), Date(2026, July, 15))
  let assert Some(LocationRecord(timezone: tz_before, ..)) =
    priya(before).location
  let assert Some(LocationRecord(timezone: tz_after, ..)) =
    priya(after).location
  assert tz_before == "Australia/Sydney"
  assert tz_after == "Europe/London"
}
