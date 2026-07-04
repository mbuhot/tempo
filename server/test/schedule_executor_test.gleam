import gleam/list
import gleam/option
import gleam/set
import gleam/time/calendar.{Date}
import pog
import shared/access
import shared/allocation/command as allocation_command
import shared/command as gateway
import shared/engagement/command as engagement_command
import shared/schedule/view as shared_schedule
import tempo/server/auth.{type Principal, Principal}
import tempo/server/operation
import tempo/server/schedule/executor
import tempo/server/schedule/view as schedule_view
import test_pool

fn rolling_back(body: fn(pog.Connection) -> a) -> a {
  let assert Error(pog.TransactionRolledBack(value)) =
    pog.transaction(test_pool.db(), fn(conn) { Error(body(conn)) })
  value
}

fn admin_principal() -> Principal {
  Principal(
    account_id: 0,
    actor: "Admin",
    engineer_id: option.None,
    permissions: set.from_list(access.all()),
  )
}

fn engineer_principal() -> Principal {
  Principal(
    account_id: 1,
    actor: "Engineer",
    engineer_id: option.None,
    permissions: set.new(),
  )
}

fn assign(
  engineer_id: Int,
  project_id: Int,
  fraction: Float,
) -> gateway.Command {
  gateway.AllocationCommand(allocation_command.AssignToProject(
    engineer_id:,
    project_id:,
    fraction:,
    valid_from: Date(2026, calendar.August, 1),
    valid_to: Date(2027, calendar.January, 1),
  ))
}

pub fn preview_leaves_the_database_unchanged_test() {
  let assert Ok(before) =
    schedule_view.timeline(test_pool.db(), Date(2026, calendar.June, 15))
  let assert Ok(previewed) =
    executor.preview(
      test_pool.ctx(),
      admin_principal(),
      Date(2026, calendar.June, 15),
      [assign(3, 500, 0.5)],
    )
  let assert Ok(after) =
    schedule_view.timeline(test_pool.db(), Date(2026, calendar.June, 15))
  assert previewed.outcomes == [shared_schedule.OperationApplied]
  assert after == before
  assert previewed.schedule != before
}

pub fn a_rejected_op_rolls_back_to_its_savepoint_and_the_rest_evaluate_test() {
  let assert Ok(previewed) =
    executor.preview(
      test_pool.ctx(),
      admin_principal(),
      Date(2026, calendar.June, 15),
      [
        gateway.EngagementCommand(engagement_command.RescheduleProject(
          project_id: 500,
          valid_from: Date(2026, calendar.May, 1),
          valid_to: Date(2026, calendar.August, 1),
        )),
        assign(3, 500, 0.5),
      ],
    )
  let assert [
    shared_schedule.OperationRejected(..),
    shared_schedule.OperationApplied,
  ] = previewed.outcomes
  let assert Ok(edge) =
    list.find(previewed.schedule.projects, fn(project) {
      project.project_id == 500
    })
  let assert option.Some(_) = edge.annotation
  let assert Ok(aisha_lane) =
    list.find(edge.lanes, fn(lane) { lane.engineer_id == 3 })
  let assert Ok(week_of_aug_3) = aisha_lane.cells |> list.drop(7) |> list.first
  assert week_of_aug_3
    == shared_schedule.Working(fraction: 0.5, over_allocated: True)
}

pub fn apply_commits_and_is_all_or_nothing_test() {
  let outcome =
    rolling_back(fn(conn) {
      let bad_then_good = [
        gateway.EngagementCommand(engagement_command.RescheduleProject(
          project_id: 100,
          valid_from: Date(2024, calendar.February, 1),
          valid_to: Date(2027, calendar.January, 1),
        )),
        assign(3, 500, 0.5),
      ]
      executor.apply_in(
        conn,
        "tester",
        Date(2026, calendar.June, 15),
        bad_then_good,
      )
    })
  assert outcome == Error(operation.ProjectPinned)
}

pub fn preview_refuses_an_unauthorized_operation_test() {
  let outcome =
    executor.preview(
      test_pool.ctx(),
      engineer_principal(),
      Date(2026, calendar.June, 15),
      [assign(3, 500, 0.5)],
    )
  let assert Error(operation.Unauthorized(..)) = outcome
}
