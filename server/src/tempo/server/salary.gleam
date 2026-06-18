//// Domain: the salary aggregate — what we PAY a level over time, the cost analogue
//// of `rate_card` (what we CHARGE). `handle` routes the salary command to a named
//// operation that does ONLY its temporal write on the in-transaction connection and
//// classifies any database rejection; `command.dispatch` owns the transaction and
//// persists the journal event(s) `handle` returns. No HTTP — never imports `wisp`.
////
//// `set_salary` is a Change (FOR PORTION OF … FROM effective TO NULL, re-rate from a
//// date onward with the `@>` guard leaving a scheduled-future version untouched),
//// exactly like `revise_rate_card` on `rate_card`.

import gleam/float
import gleam/int
import pog
import shared/codecs
import shared/types.{type Command, SetSalary}
import tempo/server/operation.{type Event, type OperationError, Event}
import tempo/server/sql

/// Apply a salary-aggregate command: route it to its named operation, which does its
/// temporal write and returns the journal event(s) it produced. The dispatch `route`
/// only ever sends salary commands here, so any other variant is a routing bug —
/// `panic`.
pub fn handle(
  conn: pog.Connection,
  command: Command,
) -> Result(List(Event), OperationError) {
  case command {
    SetSalary(..) -> set_salary(conn, command)
    _ ->
      panic as "salary.handle: command not owned by this aggregate (dispatch bug)"
  }
}

/// Set a level's monthly salary from a date onward (Change, FOR PORTION OF … TO
/// NULL), then return its journal event; the `@>` guard confines it to the version
/// in effect, leaving a scheduled-future salary untouched.
fn set_salary(
  conn: pog.Connection,
  command: Command,
) -> Result(List(Event), OperationError) {
  let assert SetSalary(level:, monthly_salary:, effective:) = command
  use _ <- operation.try(sql.salary_revise(
    conn,
    effective,
    monthly_salary,
    level,
  ))
  Ok([
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
  ])
}
