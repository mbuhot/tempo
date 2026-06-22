//// Domain: the project capacity-requirement aggregate — a project's demand for
//// `quantity` FTE at a `level`, versioned over time. `handle` routes each
//// requirement command to a named operation that returns the `Fact`s it records;
//// `command.dispatch` records them (through `repository`) and persists the journal
//// in ONE transaction. No HTTP — never imports `wisp`.
////
//// `set_project_requirement` is the bounded surgical write: a FOR-PORTION-OF set on
//// `(project_id, level)` over `[valid_from, valid_to)`, mirroring
//// `rate_card.adjust_rate_for_portion`.

import gleam/float
import gleam/int
import pog
import shared/codecs
import shared/types.{type Command, SetProjectRequirement}
import tempo/server/fact.{type Recorded, Recorded}
import tempo/server/operation.{type OperationError, Event}

/// Apply a project-requirement command: route it to its named operation, which
/// returns the audit entry and facts it records. The dispatch `route` only ever
/// sends requirement commands here, so any other variant is a routing bug — `panic`.
pub fn handle(
  _conn: pog.Connection,
  command: Command,
) -> Result(Recorded, OperationError) {
  case command {
    SetProjectRequirement(..) -> set_project_requirement(command)
    _ ->
      panic as "project_requirement.handle: command not owned by this aggregate (dispatch bug)"
  }
}

/// Set a project's capacity requirement for a bounded window `[valid_from, valid_to)`,
/// with the journal entry.
fn set_project_requirement(
  command: Command,
) -> Result(Recorded, OperationError) {
  let assert SetProjectRequirement(
    project_id:,
    level:,
    quantity:,
    valid_from:,
    valid_to:,
  ) = command
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
