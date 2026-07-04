//// Preview/apply a scenario: run a batch of commands through the ordinary
//// dispatch_in seam inside ONE transaction, evaluate the timeline on the same
//// connection, then roll back (preview) or commit (apply). Preview wraps each
//// command in a savepoint so a rejected draft reports its outcome and the rest
//// still evaluate; apply is all-or-nothing.

import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/time/calendar.{type Date}
import pog
import shared/allocation/command as allocation_command
import shared/command.{type Command, AllocationCommand, EngagementCommand}
import shared/engagement/command as engagement_command
import shared/schedule/view.{
  type PreviewResult, OperationApplied, OperationRejected, PreviewResult,
} as shared_schedule
import tempo/server/auth.{type Principal, Forbidden}
import tempo/server/command as dispatch
import tempo/server/context.{type Context}
import tempo/server/operation.{type OperationError}
import tempo/server/schedule/view as schedule_view

type Rolled {
  Evaluated(PreviewResult)
  Failed(OperationError)
}

/// Preview a scenario: authorize every op up front, then run it inside a
/// transaction that ALWAYS rolls back — savepoints around each op let a
/// rejection stop just that op while the timeline still reflects the ones that
/// applied. Never mutates the database.
pub fn preview(
  ctx: Context,
  principal: Principal,
  as_of: Date,
  commands: List(Command),
) -> Result(PreviewResult, OperationError) {
  use actor <- result.try(authorize_all(principal, commands))
  case
    pog.transaction(ctx.db, fn(conn) {
      Error(case preview_in(conn, actor, as_of, commands) {
        Ok(previewed) -> Evaluated(previewed)
        Error(error) -> Failed(error)
      })
    })
  {
    Error(pog.TransactionRolledBack(Evaluated(previewed))) -> Ok(previewed)
    Error(pog.TransactionRolledBack(Failed(error))) -> Error(error)
    Error(pog.TransactionQueryError(query_error)) ->
      Error(operation.classify(query_error))
    Ok(_) -> panic as "preview always rolls back"
  }
}

/// Apply a scenario: authorize every op up front, then run it inside a
/// transaction that commits only when every op applies (a rejection rolls the
/// whole batch back).
pub fn apply(
  ctx: Context,
  principal: Principal,
  as_of: Date,
  commands: List(Command),
) -> Result(PreviewResult, OperationError) {
  use actor <- result.try(authorize_all(principal, commands))
  case
    pog.transaction(ctx.db, fn(conn) { apply_in(conn, actor, as_of, commands) })
  {
    Ok(applied) -> Ok(applied)
    Error(pog.TransactionRolledBack(error)) -> Error(error)
    Error(pog.TransactionQueryError(query_error)) ->
      Error(operation.classify(query_error))
  }
}

/// The transaction-free core of `preview`: run each command on the given
/// (already-open) connection under its own savepoint, releasing it when the
/// command applies and rolling back to it when rejected, then evaluate the
/// timeline on the SAME connection so it reflects whatever applied. The caller
/// owns the transaction and its eventual rollback.
pub fn preview_in(
  conn: pog.Connection,
  actor: String,
  as_of: Date,
  commands: List(Command),
) -> Result(PreviewResult, OperationError) {
  use outcomes <- result.try(
    commands
    |> list.index_map(fn(command, index) { #(index, command) })
    |> list.try_map(fn(indexed) {
      let #(index, command) = indexed
      let savepoint = "scenario_op_" <> int.to_string(index)
      use _ <- result.try(run_sql(conn, "SAVEPOINT " <> savepoint))
      case dispatch.dispatch_in(conn, actor, command) {
        Ok(_event) -> {
          use _ <- result.map(run_sql(conn, "RELEASE SAVEPOINT " <> savepoint))
          #(command, OperationApplied)
        }
        Error(error) -> {
          use _ <- result.map(run_sql(
            conn,
            "ROLLBACK TO SAVEPOINT " <> savepoint,
          ))
          #(command, OperationRejected(detail: operation.describe(error)))
        }
      }
    }),
  )
  use timeline <- result.map(
    schedule_view.timeline(conn, as_of)
    |> result.map_error(operation.classify),
  )
  PreviewResult(
    schedule: annotate(timeline, outcomes),
    outcomes: list.map(outcomes, fn(pair) { pair.1 }),
  )
}

/// The transaction-free core of `apply`: run every command on the given
/// (already-open) connection through the ordinary `dispatch_in` seam, stopping
/// at the first rejection (the caller's transaction then rolls the whole batch
/// back), then evaluate the timeline on the same connection.
pub fn apply_in(
  conn: pog.Connection,
  actor: String,
  as_of: Date,
  commands: List(Command),
) -> Result(PreviewResult, OperationError) {
  use _ <- result.try(
    list.try_map(commands, fn(command) {
      dispatch.dispatch_in(conn, actor, command)
    }),
  )
  use timeline <- result.map(
    schedule_view.timeline(conn, as_of)
    |> result.map_error(operation.classify),
  )
  PreviewResult(
    schedule: timeline,
    outcomes: list.map(commands, fn(_) { OperationApplied }),
  )
}

/// Authorize every command against the principal BEFORE any transaction opens
/// (mirroring `command.dispatch`'s single gate) — a batch with even one
/// forbidden op is refused outright, never partially run. Returns the
/// principal's actor to stamp on the journal.
fn authorize_all(
  principal: Principal,
  commands: List(Command),
) -> Result(String, OperationError) {
  list.try_fold(commands, "", fn(_actor, command) {
    case auth.authorize(principal, command) {
      Ok(actor) -> Ok(actor)
      Error(Forbidden(actor:, command:)) ->
        Error(operation.Unauthorized(actor:, command:))
    }
  })
}

fn run_sql(conn: pog.Connection, sql: String) -> Result(Nil, OperationError) {
  pog.query(sql)
  |> pog.execute(on: conn)
  |> result.replace(Nil)
  |> result.map_error(operation.classify)
}

/// Pin the rejection detail of a rejected op onto its target project's
/// `annotation`, so the inspector can show why a draft failed beside the
/// project it targeted.
fn annotate(
  timeline: shared_schedule.Schedule,
  outcomes: List(#(Command, shared_schedule.OperationOutcome)),
) -> shared_schedule.Schedule {
  let rejected_projects =
    list.filter_map(outcomes, fn(pair) {
      case pair {
        #(command, OperationRejected(detail:)) ->
          case command_project(command) {
            Some(project_id) -> Ok(#(project_id, detail))
            None -> Error(Nil)
          }
        _ -> Error(Nil)
      }
    })
  shared_schedule.Schedule(
    ..timeline,
    projects: list.map(timeline.projects, fn(project) {
      case list.key_find(rejected_projects, project.project_id) {
        Ok(detail) ->
          shared_schedule.ProjectSchedule(..project, annotation: Some(detail))
        Error(Nil) -> project
      }
    }),
  )
}

/// The project a command targets, for pinning a rejection's detail to the
/// right project header; `None` for a command with no single project target.
fn command_project(command: Command) -> option.Option(Int) {
  case command {
    EngagementCommand(engagement_command.RescheduleProject(project_id:, ..)) ->
      Some(project_id)
    AllocationCommand(allocation_command.AssignToProject(project_id:, ..)) ->
      Some(project_id)
    AllocationCommand(allocation_command.ChangeAllocationFraction(
      project_id:,
      ..,
    )) -> Some(project_id)
    AllocationCommand(allocation_command.RollOff(project_id:, ..)) ->
      Some(project_id)
    _ -> None
  }
}
