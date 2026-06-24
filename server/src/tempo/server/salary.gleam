//// Domain: the salary aggregate — what we PAY a level over time, the cost analogue
//// of `rate_card` (what we CHARGE). `command.route` destructures the salary command
//// and calls the operation here with its already-narrowed fields; the operation
//// returns the `Fact`s it records, and `command.dispatch` records them (through
//// `repository`) and persists the journal in ONE transaction. No HTTP — never
//// imports `wisp`.
////
//// `set_salary` re-rates the level's monthly salary from `effective` onward (the
//// repository's change), exactly like `revise_rate_card` on `rate_card`.

import gleam/float
import gleam/int
import gleam/time/calendar.{type Date}
import shared/codecs
import shared/types.{type SalaryCommand, SalaryCommand, SetSalary}
import tempo/server/fact.{type Recorded, Recorded}
import tempo/server/operation.{type OperationError, Event}

/// Route a salary command to its operation, returning the audit entry and the facts
/// it records. Exhaustive over `SalaryCommand`.
pub fn route(command: SalaryCommand) -> Result(Recorded, OperationError) {
  case command {
    SetSalary(level:, monthly_salary:, effective:) ->
      set_salary(command, level:, monthly_salary:, effective:)
  }
}

/// Set a level's monthly salary from `effective` onward, with the journal entry.
pub fn set_salary(
  command: SalaryCommand,
  level level: Int,
  monthly_salary monthly_salary: Float,
  effective effective: Date,
) -> Result(Recorded, OperationError) {
  Ok(
    Recorded(
      entry: Event(
        operation: "set_salary",
        summary: "Set L"
          <> int.to_string(level)
          <> " salary to "
          <> float.to_string(monthly_salary)
          <> " from "
          <> operation.iso(effective),
        payload: codecs.encode_command(SalaryCommand(command)),
      ),
      facts: [fact.Salary(level:, monthly_salary:, from: effective)],
    ),
  )
}
