//// Domain: the salary aggregate — what we PAY a level over time, the cost analogue
//// of `rate_card` (what we CHARGE). `handle` matches the salary commands, does ONLY
//// their temporal writes on the in-transaction connection, classifies any database
//// rejection, and returns the journal event(s) it produced; `command.dispatch` owns
//// the transaction and persists those events. No HTTP — never imports `wisp`.
////
//// `SetSalary` is a Change (FOR PORTION OF … FROM effective TO NULL, re-rate from a
//// date onward with the `@>` guard leaving a scheduled-future version untouched),
//// exactly like `ReviseRateCard` on `rate_card`.

import gleam/float
import gleam/int
import gleam/result
import pog
import shared/codecs
import shared/types.{type Command, SetSalary}
import tempo/server/operation.{type Event, type OperationError, Event}
import tempo/server/sql

/// Apply a salary-aggregate command: run its temporal writes on the in-transaction
/// connection, classify any database rejection, and on success return the single
/// journal event it produced. Only the salary commands reach here (the dispatch
/// `route` guarantees it); any other variant is a no-op.
pub fn handle(
  conn: pog.Connection,
  command: Command,
) -> Result(List(Event), OperationError) {
  let written = case command {
    SetSalary(level:, monthly_salary:, effective:) ->
      sql.salary_revise(conn, effective, monthly_salary, level)
      |> result.replace(Nil)
    _ -> Ok(Nil)
  }
  case written {
    Error(query_error) -> Error(operation.classify(query_error))
    Ok(Nil) -> Ok(events(command))
  }
}

/// The journal event(s) an applied salary command produces.
fn events(command: Command) -> List(Event) {
  case command {
    SetSalary(level:, monthly_salary:, effective:) -> [
      Event(
        operation: "set_salary",
        summary: "Set L"
          <> int.to_string(level)
          <> " salary to "
          <> float.to_string(monthly_salary)
          <> " from "
          <> operation.iso(effective),
        payload: codecs.encode_command(command),
      ),
    ]
    _ -> []
  }
}
