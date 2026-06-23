//// Domain: the project capacity-requirement aggregate — a project's demand for
//// `quantity` FTE at a `level`, versioned over time. `command.route` destructures
//// the requirement command and calls the operation here with its already-narrowed
//// fields; the operation returns the `Fact`s it records, and `command.dispatch`
//// records them (through `repository`) and persists the journal in ONE transaction.
//// No HTTP — never imports `wisp`.
////
//// `set_project_requirement` is the bounded surgical write: a FOR-PORTION-OF set on
//// `(project_id, level)` over `[valid_from, valid_to)`, mirroring
//// `rate_card.adjust_rate_for_portion`.

import gleam/float
import gleam/int
import gleam/time/calendar.{type Date}
import shared/codecs
import shared/types.{type Command}
import tempo/server/fact.{type Recorded, Recorded}
import tempo/server/operation.{type OperationError, Event}

/// Set a project's capacity requirement for a bounded window `[valid_from, valid_to)`,
/// with the journal entry.
pub fn set_project_requirement(
  command: Command,
  project_id project_id: Int,
  level level: Int,
  quantity quantity: Float,
  valid_from valid_from: Date,
  valid_to valid_to: Date,
) -> Result(Recorded, OperationError) {
  Ok(
    Recorded(
      entry: Event(
        operation: "set_project_requirement",
        summary: "Set requirement: "
          <> float.to_string(quantity)
          <> "x L"
          <> int.to_string(level)
          <> " on project "
          <> int.to_string(project_id)
          <> " over "
          <> operation.span(valid_from, valid_to),
        payload: codecs.encode_command(command),
      ),
      facts: [
        fact.ProjectRequirement(
          project_id: fact.ProjectId(project_id),
          level:,
          quantity:,
          from: valid_from,
          to: valid_to,
        ),
      ],
    ),
  )
}
