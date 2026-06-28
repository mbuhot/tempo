//// The draft instance lifecycle: starting a workflow, appending field values,
//// advancing the open step, handing off to Finance, cancelling, and assembling the
//// `DraftView`/`DraftSummary` read models. Draft mutations are plain writes — NOT
//// journaled commands — so autosave never floods the event log; only the commit
//// (see `workflow/commit`) is journaled.

import gleam/dict.{type Dict}
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import pog
import shared/workflow/value.{type FieldValue}
import shared/workflow/view.{
  type DraftSummary, type DraftView, type StepStatus, Active, Done, DraftSummary,
  DraftView, Pending,
}
import tempo/server/operation.{type OperationError}
import tempo/server/workflow/sql

/// The lifecycle status of a draft instance.
pub type Status {
  Draft
  AwaitingFinance
  Committed
  Cancelled
}

/// A draft instance as loaded from its row.
pub type Instance {
  Instance(
    id: String,
    kind: String,
    status: Status,
    owner_id: Int,
    assignee_id: Option(Int),
    current_step: String,
  )
}

pub fn status_from_string(text: String) -> Status {
  case text {
    "awaiting_finance" -> AwaitingFinance
    "committed" -> Committed
    "cancelled" -> Cancelled
    _ -> Draft
  }
}

pub fn status_to_string(status: Status) -> String {
  case status {
    Draft -> "draft"
    AwaitingFinance -> "awaiting_finance"
    Committed -> "committed"
    Cancelled -> "cancelled"
  }
}

/// Open a new draft of `kind`, owned by `owner_id`, at its `first_step`. Returns the
/// generated instance id.
pub fn start(
  conn: pog.Connection,
  kind kind: String,
  owner_id owner_id: Int,
  first_step first_step: String,
) -> Result(String, OperationError) {
  use returned <- operation.try(sql.instance_start(
    conn,
    kind,
    owner_id,
    first_step,
  ))
  let assert [row] = returned.rows
  Ok(row.id)
}

/// Record a step document. Supersedes the current open transaction-time version;
/// a document equal to the current one writes nothing.
pub fn save_step(
  conn: pog.Connection,
  instance_id instance_id: String,
  step_id step_id: String,
  values values: Dict(String, FieldValue),
) -> Result(Nil, OperationError) {
  sql.step_value_set(conn, instance_id, step_id, value.encode_step(values))
  |> operation.run
}

/// Move the draft's open step to `next_step`.
pub fn complete_step(
  conn: pog.Connection,
  instance_id instance_id: String,
  next_step next_step: String,
) -> Result(Nil, OperationError) {
  sql.instance_set_step(conn, instance_id, next_step) |> operation.run
}

/// Hand the draft to the Finance queue: move to `awaiting_finance` and advance the
/// open step to `finance_step`. No specific assignee — any commit-permission holder
/// can pick it up.
pub fn hand_off(
  conn: pog.Connection,
  instance_id instance_id: String,
  finance_step finance_step: String,
) -> Result(Nil, OperationError) {
  sql.instance_handoff(conn, instance_id, finance_step) |> operation.run
}

/// Cancel the draft (retained for audit; excluded from resume lists).
pub fn cancel(
  conn: pog.Connection,
  instance_id instance_id: String,
) -> Result(Nil, OperationError) {
  sql.instance_set_status(conn, instance_id, "cancelled") |> operation.run
}

/// Mark the draft committed — its facts have been written.
pub fn mark_committed(
  conn: pog.Connection,
  instance_id instance_id: String,
) -> Result(Nil, OperationError) {
  sql.instance_set_status(conn, instance_id, "committed") |> operation.run
}

/// Load a draft instance, or `None` if no such id.
pub fn load(
  conn: pog.Connection,
  instance_id instance_id: String,
) -> Result(Option(Instance), OperationError) {
  use returned <- operation.try(sql.instance_by_id(conn, instance_id))
  case returned.rows {
    [] -> Ok(None)
    [row, ..] ->
      Ok(
        Some(Instance(
          id: row.id,
          kind: row.kind,
          status: status_from_string(row.status),
          owner_id: row.owner_id,
          assignee_id: row.assignee_id,
          current_step: row.current_step,
        )),
      )
  }
}

/// The current step documents, keyed step_id → field_key → FieldValue.
pub fn current_values(
  conn: pog.Connection,
  instance_id instance_id: String,
) -> Result(Dict(String, Dict(String, FieldValue)), OperationError) {
  use returned <- operation.try(sql.step_values_current(conn, instance_id))
  returned.rows
  |> list.filter_map(fn(row) {
    case json.parse(row.value, value.step_decoder()) {
      Ok(step_values) -> Ok(#(row.step_id, step_values))
      Error(_) -> Error(Nil)
    }
  })
  |> dict.from_list
  |> Ok
}

/// Assemble the `DraftView` for the viewer `me`, or `None` if no such instance.
/// `can_commit` is whether the viewer holds the commit permission, which decides
/// whether they may act on an instance that is awaiting Finance.
pub fn draft_view(
  conn: pog.Connection,
  instance_id instance_id: String,
  me me: Int,
  can_commit can_commit: Bool,
  ids ids: List(String),
) -> Result(Option(DraftView), OperationError) {
  use maybe <- result.try(load(conn, instance_id))
  case maybe {
    None -> Ok(None)
    Some(instance) -> {
      use values <- result.try(current_values(conn, instance_id))
      Ok(
        Some(DraftView(
          instance_id: instance.id,
          kind: instance.kind,
          status: status_to_string(instance.status),
          current_step: instance.current_step,
          can_act: acts_now(instance, me, can_commit),
          values:,
          step_status: compute_step_status(ids, instance.current_step),
        )),
      )
    }
  }
}

/// The open drafts `account_id` can resume — those they own, plus (when they can
/// commit) every draft in the Finance queue.
pub fn list_for(
  conn: pog.Connection,
  account_id account_id: Int,
  can_commit can_commit: Bool,
) -> Result(List(DraftSummary), OperationError) {
  use returned <- operation.try(sql.instance_list_for(
    conn,
    account_id,
    can_commit,
  ))
  returned.rows
  |> list.map(fn(row) {
    DraftSummary(
      instance_id: row.id,
      kind: row.kind,
      status: row.status,
      title: title_for(row.kind),
      current_step: row.current_step,
      awaiting_me: row.status == "awaiting_finance" && can_commit,
    )
  })
  |> Ok
}

/// Whether `me` may act on the instance now: the owner while it is a draft, anyone
/// holding the commit permission once it is awaiting Finance.
fn acts_now(instance: Instance, me: Int, can_commit: Bool) -> Bool {
  case instance.status {
    Draft -> instance.owner_id == me
    AwaitingFinance -> can_commit
    Committed | Cancelled -> False
  }
}

fn title_for(kind: String) -> String {
  case kind {
    "onboard_engineer" -> "Onboard engineer"
    "create_project" -> "Create a project"
    _ -> kind
  }
}

fn compute_step_status(
  ids: List(String),
  current_step: String,
) -> Dict(String, StepStatus) {
  let current_index = index_of(ids, current_step, 0)
  ids
  |> list.index_map(fn(id, index) {
    let status = case index < current_index, index == current_index {
      True, _ -> Done
      _, True -> Active
      _, _ -> Pending
    }
    #(id, status)
  })
  |> dict.from_list
}

fn index_of(ids: List(String), target: String, at: Int) -> Int {
  case ids {
    [] -> -1
    [head, ..rest] ->
      case head == target {
        True -> at
        False -> index_of(rest, target, at + 1)
      }
  }
}
