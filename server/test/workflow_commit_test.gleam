//// Committing a confirmed onboarding draft mints an engineer and the employment,
//// role, contact and banking facts from the saved values, and marks the instance
//// committed. A draft not yet awaiting Finance is refused.

import gleam/dict
import gleam/dynamic/decode
import gleam/option.{Some}
import gleam/time/calendar.{Date, July}
import pog
import shared/workflow/command.{CommitOnboarding}
import shared/workflow/value.{BoolValue, DateValue, TextValue}
import tempo/server/fact.{
  EngineerAtLevel, EngineerBankingDetails, EngineerContactDetails,
  EngineerEmployed, Recorded,
}
import tempo/server/operation
import tempo/server/workflow/commit
import tempo/server/workflow/instance.{Committed}
import tempo/server/workflow/schema as flow
import test_pool

fn rolling_back(body: fn(pog.Connection) -> a) -> a {
  let outcome = pog.transaction(test_pool.db(), fn(conn) { Error(body(conn)) })
  let assert Error(pog.TransactionRolledBack(value)) = outcome
  value
}

fn account_id(conn: pog.Connection) -> Int {
  let decoder = {
    use id <- decode.field(0, decode.int)
    decode.success(id)
  }
  let assert Ok(returned) =
    pog.query("SELECT id FROM account ORDER BY id LIMIT 1")
    |> pog.returning(decoder)
    |> pog.execute(conn)
  let assert [id] = returned.rows
  id
}

fn save_step(conn, id, step, fields) {
  let assert Ok(_) = instance.save_step(conn, id, step, dict.from_list(fields))
  Nil
}

/// Start an onboarding draft and fill every required field + confirm payroll. Leaves
/// the instance a `draft` (no hand-off).
fn fill_complete(conn: pog.Connection, owner: Int) -> String {
  let assert Ok(id) = instance.start(conn, flow.kind, owner, flow.first_step)
  save_step(conn, id, "identity", [
    #("full_name", TextValue("Aisha Okafor")),
    #("work_email", TextValue("aisha@example.com")),
  ])
  save_step(conn, id, "level", [#("level", TextValue("5"))])
  save_step(conn, id, "employment", [
    #("start_date", DateValue(Date(2026, July, 13))),
  ])
  save_step(conn, id, "banking", [
    #("bank", TextValue("ANZ")),
    #("account_no", TextValue("00112233")),
    #("account_name", TextValue("A Okafor")),
  ])
  save_step(conn, id, "payroll", [#("payroll_confirmed", BoolValue(True))])
  id
}

/// A filled draft handed off to Finance (awaiting_finance) — the Manager→Finance path.
fn ready_to_commit(conn: pog.Connection, owner: Int) -> String {
  let id = fill_complete(conn, owner)
  let assert Ok(_) = instance.hand_off(conn, id, "payroll")
  id
}

pub fn commit_writes_engineer_facts_test() {
  use conn <- rolling_back
  let owner = account_id(conn)
  let id = ready_to_commit(conn, owner)

  let assert Ok(Recorded(entry:, facts:)) =
    commit.route(conn, CommitOnboarding(id))

  assert entry.operation == "onboard_engineer"
  let assert [
    EngineerEmployed(_, employed_from),
    EngineerAtLevel(_, level, _),
    EngineerContactDetails(_, name, email, _, _, _),
    EngineerBankingDetails(_, bank, _, account_no, account_name, _),
  ] = facts
  assert employed_from == Date(2026, July, 13)
  assert level == 5
  assert name == "Aisha Okafor"
  assert email == "aisha@example.com"
  assert bank == "ANZ"
  assert account_no == "00112233"
  assert account_name == "A Okafor"
}

pub fn commit_marks_instance_committed_test() {
  use conn <- rolling_back
  let owner = account_id(conn)
  let id = ready_to_commit(conn, owner)

  let assert Ok(_) = commit.route(conn, CommitOnboarding(id))

  let assert Ok(Some(loaded)) = instance.load(conn, id)
  assert loaded.status == Committed
}

/// A filled draft can be committed directly, with no hand-off — the permission (not
/// the status) is the gate, so a holder of it onboards end-to-end (the Admin path).
pub fn commit_from_draft_without_handoff_succeeds_test() {
  use conn <- rolling_back
  let owner = account_id(conn)
  let id = fill_complete(conn, owner)

  let assert Ok(_) = commit.route(conn, CommitOnboarding(id))

  let assert Ok(Some(loaded)) = instance.load(conn, id)
  assert loaded.status == Committed
}

pub fn commit_refused_when_incomplete_test() {
  use conn <- rolling_back
  let owner = account_id(conn)
  let assert Ok(id) = instance.start(conn, flow.kind, owner, flow.first_step)

  assert commit.route(conn, CommitOnboarding(id))
    == Error(operation.InvalidValue)
}
