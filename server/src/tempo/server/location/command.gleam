//// Write handler for engineer location. `set_location` validates the TZID against
//// pg_timezone_names before recording, so an unknown zone is a clean InvalidValue.

import gleam/int
import gleam/option.{type Option}
import gleam/time/calendar.{type Date}
import pog
import shared/command as gateway
import shared/location/command.{type LocationCommand, SetEngineerLocation}
import tempo/server/fact.{type Recorded, Recorded}
import tempo/server/location/sql as location_sql
import tempo/server/operation.{type OperationError, Event}

/// Route a location command to its operation, returning the audit entry and the
/// facts it records. Exhaustive over `LocationCommand`.
pub fn route(
  conn: pog.Connection,
  command: LocationCommand,
) -> Result(Recorded, OperationError) {
  case command {
    SetEngineerLocation(engineer_id:, country:, region:, timezone:, effective:) ->
      set_location(
        conn,
        command,
        engineer_id:,
        country:,
        region:,
        timezone:,
        effective:,
      )
  }
}

/// Record an engineer's location from `effective` onward, once its IANA TZID is
/// confirmed against `pg_timezone_names`.
pub fn set_location(
  conn: pog.Connection,
  command: LocationCommand,
  engineer_id engineer_id: Int,
  country country: String,
  region region: Option(String),
  timezone timezone: String,
  effective effective: Date,
) -> Result(Recorded, OperationError) {
  use valid <- operation.try(location_sql.timezone_valid(conn, timezone))
  let assert [check] = valid.rows
  case check.valid {
    False -> Error(operation.InvalidValue)
    True ->
      Ok(
        Recorded(
          entry: Event(
            operation: "set_engineer_location",
            summary: "Set location of engineer "
              <> int.to_string(engineer_id)
              <> " to "
              <> timezone
              <> " ("
              <> country
              <> ") from "
              <> operation.iso(effective),
            payload: gateway.encode_command(gateway.LocationCommand(command)),
          ),
          facts: [
            fact.EngineerLocated(
              engineer_id: fact.EngineerId(engineer_id),
              country:,
              region:,
              timezone:,
              from: effective,
            ),
          ],
        ),
      )
  }
}
