//// Committing a confirmed create_project draft mints contract and project anchors,
//// writes ContractTerms/ProjectRun/ProjectProfile/ProjectPlan facts from the saved
//// values, and marks the instance committed. The new-client path additionally emits
//// a ClientProfile.

import gleam/dynamic/decode
import gleam/int
import gleam/time/calendar.{Date, December, January, July}
import pog
import shared/money
import shared/workflow/command.{CreateProject}
import shared/workflow/value.{BoolValue, DateValue, MoneyValue, TextValue}
import tempo/server/fact.{
  ClientProfile, ContractTerms, ProjectPlan, ProjectProfile, ProjectRun,
  Recorded,
}
import tempo/server/workflow/commit
import tempo/server/workflow/instance
import tempo/server/workflow/project_schema
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

fn seeded_client_id(conn: pog.Connection) -> Int {
  let decoder = {
    use id <- decode.field(0, decode.int)
    decode.success(id)
  }
  let assert Ok(returned) =
    pog.query("SELECT id FROM client ORDER BY id LIMIT 1")
    |> pog.returning(decoder)
    |> pog.execute(conn)
  let assert [id] = returned.rows
  id
}

fn save(conn, id, step, field, field_value) {
  let assert Ok(_) =
    instance.save_field(conn, id, step, field, value.encode(field_value))
  Nil
}

fn fill_project_draft(
  conn: pog.Connection,
  owner: Int,
  client_field_value: String,
) -> String {
  let assert Ok(id) = instance.start(conn, project_schema.kind, owner, "client")
  save(conn, id, "client", "client", TextValue(client_field_value))
  save(conn, id, "description", "title", TextValue("Website Rebuild"))
  save(
    conn,
    id,
    "description",
    "summary",
    TextValue("Rebuild the marketing site"),
  )
  save(conn, id, "timeframe", "start", DateValue(Date(2026, July, 1)))
  save(conn, id, "timeframe", "end", DateValue(Date(2026, December, 31)))
  let assert Ok(budget_money) = money.from_string("50000.00")
  save(conn, id, "timeframe", "budget", MoneyValue(budget_money))
  save(conn, id, "contract", "contract_from", DateValue(Date(2026, July, 1)))
  save(conn, id, "contract", "contract_to", DateValue(Date(2027, January, 1)))
  save(conn, id, "confirm", "confirmed", BoolValue(True))
  id
}

pub fn commit_existing_client_writes_project_facts_test() {
  use conn <- rolling_back
  let owner = account_id(conn)
  let client_id = seeded_client_id(conn)
  let id = fill_project_draft(conn, owner, int.to_string(client_id))

  let assert Ok(Recorded(entry:, facts:)) =
    commit.route(conn, CreateProject(id))

  assert entry.operation == "create_project"
  let assert [
    ContractTerms(_, client_name, _, _),
    ProjectRun(_, _, run_from, run_to),
    ProjectProfile(_, title, summary, _),
    ProjectPlan(_, budget, target, _),
  ] = facts
  assert client_name == "Northwind Trading"
  assert run_from == Date(2026, July, 1)
  assert run_to == Date(2026, December, 31)
  assert title == "Website Rebuild"
  assert summary == "Rebuild the marketing site"
  assert money.to_string(budget) == "50000.00"
  assert target == Date(2026, December, 31)
}

pub fn commit_new_client_emits_client_profile_test() {
  use conn <- rolling_back
  let owner = account_id(conn)
  let id = fill_project_draft(conn, owner, "__new__")
  save(conn, id, "client", "new_client_name", TextValue("Acme Corp"))

  let assert Ok(Recorded(facts:, ..)) = commit.route(conn, CreateProject(id))

  let assert [
    ClientProfile(_, client_name, _),
    ContractTerms(_, contract_client, _, _),
    ProjectRun(..),
    ProjectProfile(..),
    ProjectPlan(..),
  ] = facts
  assert client_name == "Acme Corp"
  assert contract_client == "Acme Corp"
}

pub fn commit_defaults_target_completion_to_end_test() {
  use conn <- rolling_back
  let owner = account_id(conn)
  let client_id = seeded_client_id(conn)
  let id = fill_project_draft(conn, owner, int.to_string(client_id))

  let assert Ok(Recorded(facts:, ..)) = commit.route(conn, CreateProject(id))

  let assert [_, _, _, ProjectPlan(_, _, target, _)] = facts
  assert target == Date(2026, December, 31)
}
