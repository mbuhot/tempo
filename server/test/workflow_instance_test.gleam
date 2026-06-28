//// The draft instance lifecycle, exercised inside a rolling-back transaction: a
//// started draft persists field values (latest wins), advances its step, hands off
//// to Finance, and surfaces in the resume list.

import gleam/dict
import gleam/dynamic/decode
import gleam/list
import gleam/option.{Some}
import pog
import shared/workflow/value.{TextValue}
import shared/workflow/view.{Active, Done, Pending}
import tempo/server/workflow/instance.{AwaitingFinance}
import tempo/server/workflow/schema as flow
import test_pool

fn rolling_back(body: fn(pog.Connection) -> a) -> a {
  let outcome = pog.transaction(test_pool.db(), fn(conn) { Error(body(conn)) })
  let assert Error(pog.TransactionRolledBack(value)) = outcome
  value
}

/// Two distinct existing account ids, for owner and assignee.
fn two_account_ids(conn: pog.Connection) -> #(Int, Int) {
  let decoder = {
    use id <- decode.field(0, decode.int)
    decode.success(id)
  }
  let assert Ok(returned) =
    pog.query("SELECT id FROM account ORDER BY id LIMIT 2")
    |> pog.returning(decoder)
    |> pog.execute(conn)
  let assert [owner, assignee] = returned.rows
  #(owner, assignee)
}

pub fn save_then_draft_view_shows_value_test() {
  use conn <- rolling_back
  let #(owner, _) = two_account_ids(conn)
  let assert Ok(id) = instance.start(conn, flow.kind, owner, flow.first_step)

  let assert Ok(_) =
    instance.save_field(
      conn,
      id,
      "identity",
      "full_name",
      value.encode(TextValue("Aisha Okafor")),
    )

  let assert Ok(Some(draft)) = instance.draft_view(conn, id, owner, False)
  assert dict.get(draft.values, "identity.full_name")
    == Ok(TextValue("Aisha Okafor"))
  assert draft.current_step == "identity"
  assert draft.can_act == True
}

/// Every version (open + closed) recorded for a field.
fn version_count(
  conn: pog.Connection,
  instance_id: String,
  field_key: String,
) -> Int {
  let decoder = {
    use count <- decode.field(0, decode.int)
    decode.success(count)
  }
  let assert Ok(returned) =
    pog.query(
      "SELECT count(*)::int FROM workflow_step_value
        WHERE instance_id = $1 AND field_key = $2",
    )
    |> pog.parameter(pog.text(instance_id))
    |> pog.parameter(pog.text(field_key))
    |> pog.returning(decoder)
    |> pog.execute(conn)
  let assert [count] = returned.rows
  count
}

pub fn unchanged_value_records_no_new_version_test() {
  use conn <- rolling_back
  let #(owner, _) = two_account_ids(conn)
  let assert Ok(id) = instance.start(conn, flow.kind, owner, flow.first_step)

  let assert Ok(_) =
    instance.save_field(
      conn,
      id,
      "identity",
      "full_name",
      value.encode(TextValue("Aisha")),
    )
  let assert Ok(_) =
    instance.save_field(
      conn,
      id,
      "identity",
      "full_name",
      value.encode(TextValue("Aisha")),
    )

  assert version_count(conn, id, "full_name") == 1
}

pub fn latest_value_wins_test() {
  use conn <- rolling_back
  let #(owner, _) = two_account_ids(conn)
  let assert Ok(id) = instance.start(conn, flow.kind, owner, flow.first_step)

  let assert Ok(_) =
    instance.save_field(
      conn,
      id,
      "identity",
      "full_name",
      value.encode(TextValue("First")),
    )
  let assert Ok(_) =
    instance.save_field(
      conn,
      id,
      "identity",
      "full_name",
      value.encode(TextValue("Second")),
    )

  let assert Ok(Some(draft)) = instance.draft_view(conn, id, owner, False)
  assert dict.get(draft.values, "identity.full_name") == Ok(TextValue("Second"))
}

pub fn complete_step_advances_and_marks_status_test() {
  use conn <- rolling_back
  let #(owner, _) = two_account_ids(conn)
  let assert Ok(id) = instance.start(conn, flow.kind, owner, flow.first_step)

  let assert Ok(_) = instance.complete_step(conn, id, "level")

  let assert Ok(Some(draft)) = instance.draft_view(conn, id, owner, False)
  assert draft.current_step == "level"
  assert dict.get(draft.step_status, "identity") == Ok(Done)
  assert dict.get(draft.step_status, "level") == Ok(Active)
  assert dict.get(draft.step_status, "banking") == Ok(Pending)
}

pub fn hand_off_queues_for_finance_test() {
  use conn <- rolling_back
  let #(owner, finance) = two_account_ids(conn)
  let assert Ok(id) = instance.start(conn, flow.kind, owner, flow.first_step)

  let assert Ok(_) = instance.hand_off(conn, id, "payroll")

  let assert Ok(Some(loaded)) = instance.load(conn, id)
  assert loaded.status == AwaitingFinance
  assert loaded.current_step == "payroll"

  let assert Ok(Some(for_finance)) =
    instance.draft_view(conn, id, finance, True)
  assert for_finance.can_act == True

  let assert Ok(Some(for_other)) = instance.draft_view(conn, id, finance, False)
  assert for_other.can_act == False
}

pub fn list_for_returns_owned_draft_test() {
  use conn <- rolling_back
  let #(owner, _) = two_account_ids(conn)
  let assert Ok(id) = instance.start(conn, flow.kind, owner, flow.first_step)

  let assert Ok(summaries) = instance.list_for(conn, owner, False)
  let ids = list.map(summaries, fn(summary) { summary.instance_id })
  assert list.contains(ids, id) == True
}

pub fn list_for_shows_finance_queue_only_to_committers_test() {
  use conn <- rolling_back
  let #(owner, finance) = two_account_ids(conn)
  let assert Ok(id) = instance.start(conn, flow.kind, owner, flow.first_step)
  let assert Ok(_) = instance.hand_off(conn, id, "payroll")

  let assert Ok(for_committer) = instance.list_for(conn, finance, True)
  let committer_ids =
    list.map(for_committer, fn(summary) { summary.instance_id })
  assert list.contains(committer_ids, id) == True

  let assert Ok(for_other) = instance.list_for(conn, finance, False)
  let other_ids = list.map(for_other, fn(summary) { summary.instance_id })
  assert list.contains(other_ids, id) == False
}
