import gleam/dynamic/decode
import gleam/time/calendar.{type Date, Date}
import pog
import shared/command as gateway
import shared/engagement/command as engagement_command
import tempo/server/command
import tempo/server/operation
import test_pool

fn rolling_back(body: fn(pog.Connection) -> a) -> a {
  let assert Error(pog.TransactionRolledBack(value)) =
    pog.transaction(test_pool.db(), fn(conn) { Error(body(conn)) })
  value
}

fn reschedule(project_id: Int, from: Date, to: Date) -> gateway.Command {
  gateway.EngagementCommand(engagement_command.RescheduleProject(
    project_id:,
    valid_from: from,
    valid_to: to,
  ))
}

fn range_rows(conn: pog.Connection, sql: String) -> List(#(String, String)) {
  let row = {
    use a <- decode.field(0, decode.string)
    use b <- decode.field(1, decode.string)
    decode.success(#(a, b))
  }
  let assert Ok(returned) =
    pog.query(sql) |> pog.returning(row) |> pog.execute(on: conn)
  returned.rows
}

pub fn reschedule_shifts_run_and_children_test() {
  let #(run, requirements) =
    rolling_back(fn(conn) {
      let assert Ok(_) =
        command.dispatch_in(
          conn,
          "tester",
          reschedule(
            500,
            Date(2026, calendar.September, 7),
            Date(2027, calendar.January, 1),
          ),
        )
      let run =
        range_rows(
          conn,
          "SELECT lower(active_during)::text, upper(active_during)::text
           FROM project_run WHERE project_id = 500",
        )
      let requirements =
        range_rows(
          conn,
          "SELECT lower(required_during)::text, upper(required_during)::text
           FROM project_requirement WHERE project_id = 500 AND level = 3",
        )
      #(run, requirements)
    })
  assert run == [#("2026-09-07", "2027-01-01")]
  assert requirements == [#("2026-11-07", "2027-01-01")]
}

pub fn reschedule_drops_children_shifted_past_the_window_test() {
  let requirements =
    rolling_back(fn(conn) {
      let assert Ok(_) =
        command.dispatch_in(
          conn,
          "tester",
          reschedule(
            500,
            Date(2026, calendar.June, 15),
            Date(2026, calendar.July, 15),
          ),
        )
      range_rows(
        conn,
        "SELECT lower(required_during)::text, upper(required_during)::text
         FROM project_requirement WHERE project_id = 500",
      )
    })
  assert requirements == []
}

pub fn reschedule_rejects_a_project_with_logged_time_test() {
  let outcome =
    rolling_back(fn(conn) {
      command.dispatch_in(
        conn,
        "tester",
        reschedule(
          100,
          Date(2024, calendar.February, 1),
          Date(2027, calendar.January, 1),
        ),
      )
    })
  assert outcome == Error(operation.ProjectPinned)
}

pub fn reschedule_rejects_a_run_outside_the_contract_test() {
  let outcome =
    rolling_back(fn(conn) {
      command.dispatch_in(
        conn,
        "tester",
        reschedule(
          500,
          Date(2026, calendar.May, 1),
          Date(2026, calendar.August, 1),
        ),
      )
    })
  assert outcome
    == Error(operation.ContainmentViolated("project_within_contract"))
}

pub fn reschedule_rejects_an_unknown_project_test() {
  let outcome =
    rolling_back(fn(conn) {
      command.dispatch_in(
        conn,
        "tester",
        reschedule(
          999,
          Date(2026, calendar.July, 1),
          Date(2026, calendar.August, 1),
        ),
      )
    })
  assert outcome == Error(operation.NoSuchVersion)
}
