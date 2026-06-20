//// Domain: the salary aggregate — what we PAY a level over time, the cost analogue
//// of `rate_card` (what we CHARGE). `handle` routes the salary command to a named
//// operation that returns the `Fact`s it records; `command.dispatch` records them
//// (through `repository`) and persists the journal in ONE transaction. No HTTP —
//// never imports `wisp`.
////
//// `set_salary` re-rates the level's monthly salary from `effective` onward (the
//// repository's change), exactly like `revise_rate_card` on `rate_card`.

import gleam/float
import gleam/int
import pog
import shared/codecs
import shared/types.{type Command, SetSalary}
import tempo/server/fact.{type Fact}
import tempo/server/operation.{type OperationError}

/// Apply a salary-aggregate command: route it to its named operation, which returns
/// the facts it records. The dispatch `route` only ever sends salary commands here,
/// so any other variant is a routing bug — `panic`.
pub fn handle(
  _conn: pog.Connection,
  command: Command,
) -> Result(List(Fact), OperationError) {
  case command {
    SetSalary(..) -> set_salary(command)
    _ ->
      panic as "salary.handle: command not owned by this aggregate (dispatch bug)"
  }
}

/// Set a level's monthly salary from `effective` onward, plus the journal entry.
fn set_salary(command: Command) -> Result(List(Fact), OperationError) {
  let assert SetSalary(level:, monthly_salary:, effective:) = command
  Ok([
    fact.Salary(level:, monthly_salary:, from: effective),
    fact.CommandHandled(
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
