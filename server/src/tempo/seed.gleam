//// The running app's founding seed, expressed as a replayed sequence of domain
//// operations (ADR-023, PRD FR-13). `commands()` is the ordered `List(Command)`
//// that narrates how Alembic came to be: engineers onboarded, contracts signed,
//// projects started, allocations made, the rate card revised mid-2026, a
//// future-dated promotion scheduled, leave taken, and a timesheet logged. Replayed
//// through `command.dispatch` it reconstructs the founding company state on a
//// freshly-migrated clean (v2) schema *and* populates `event_log` with the founding
//// history — the same data the hand-written `003_seed.sql` + `010` produce for the
//// board, but built the realistic way (every write goes through an operation).
////
////     gleam run -m tempo/seed
////
//// resets the database to a clean migrated schema (001 + 002 + 010 + 011 — every
//// migration EXCEPT `003_seed.sql`, which stays untouched as the oracle's v1
//// fixture) and replays the commands, leaving the app's founding data in place.
////
//// The minted ids are deterministic on a clean schema: `onboard_engineer` mints
//// engineers 1, 2, 3 in onboarding order (GENERATED ALWAYS AS IDENTITY), and
//// `sign_contract` / `start_project` mint contracts 1, 2 and projects 1, 2, 3 via
//// `max(id)+1` in creation order. Later commands reference those minted ids. The
//// founding ids therefore DIFFER from the v1 fixture's pinned 10/20/100/200/300,
//// but the board is compared by engineer/project/client NAME, not id (the
//// engagement window is excluded too), so the two paths produce an identical board
//// (the seed-equivalence test, ADR-023). Employment and roles are open-ended (the
//// `onboard_engineer` Assert), while contracts, projects, and allocations run to
//// the v1 horizon 2027-01-01; every sampled board date is below it, so the board
//// matches the v1 fixture everywhere.
////
//// BOOTSTRAP STATE is laid directly, not via a command, for the two things the
//// operations vocabulary has no "create" for: the CLIENT ROSTER (`register_clients`
//// — `client` is an identity table, and `sign_contract` resolves a client by name
//// rather than creating it) and the RATE-CARD BASELINE (`establish_rate_card` — the
//// rate operations only *revise* via `FOR PORTION OF`, which presupposes a covering
//// row). Both mirror exactly what `003_seed.sql` inserts. The genuine business event
//// — the mid-2026 L5 step-up — IS a `ReviseRateCard` command in the replayed list,
//// so it splits the baseline row and lands in the event log like every operation.

import gleam/erlang/application
import gleam/io
import gleam/list
import gleam/result
import gleam/string
import gleam/time/calendar.{Date, January, July, June}
import pog
import shared/types.{
  type Command, AssignToProject, LogTimesheet, OnboardEngineer, Promote,
  ReviseRateCard, SignContract, StartProject, TakeLeave,
}
import simplifile
import tempo/server/command
import tempo/server/context
import tempo/server/migrate

/// The actor recorded against every founding `event_log` row.
const seed_actor = "seed"

/// `gleam run -m tempo/seed`. Reset the database to a clean migrated (v2) schema
/// and replay the founding operations, leaving the app's founding data and its
/// `event_log` history in place. `panic`s (non-zero exit) on the first failure so
/// it gates a broken seed loudly.
pub fn main() -> Nil {
  let assert Ok(ctx) = context.start()

  io.println("Seed-as-operations (ADR-023)")
  io.println("Resetting to a clean migrated schema (001 + 002 + 010 + 011)...")
  case run(ctx) {
    Ok(applied) ->
      io.println(
        "SEED OK: replayed "
        <> string.inspect(applied)
        <> " operations; the board now reflects the founding company state.",
      )
    Error(message) -> panic as { "SEED FAILED: " <> message }
  }
}

/// Reset to a clean migrated schema, then replay the whole founding seed in ONE
/// transaction: lay the bootstrap identity/baseline state (the client roster and
/// the rate-card baseline) and replay every founding command through
/// `command.dispatch_in` (one `event_log` row per command). All-or-nothing — a
/// failure rolls the entire seed back, leaving the clean schema. Returns the
/// number of commands replayed.
pub fn run(ctx: context.Context) -> Result(Int, String) {
  let db = ctx.db
  use _ <- result.try(reset_to_clean_v2(db))
  let outcome =
    pog.transaction(db, fn(conn) {
      replay_in(conn, seed_actor)
      |> result.map_error(SeedError)
    })
  case outcome {
    Ok(count) -> Ok(count)
    Error(pog.TransactionRolledBack(SeedError(message))) -> Error(message)
    Error(other) -> Error(string.inspect(other))
  }
}

/// Wraps a seed failure message so it can ride out of `pog.transaction` via
/// `TransactionRolledBack`.
type SeedError {
  SeedError(message: String)
}

/// Lay the bootstrap identity/baseline state then replay every founding command,
/// all on an ALREADY-OPEN connection (`command.dispatch_in`, the transaction-free
/// core). The caller owns the transaction: `run` wraps it in one all-or-nothing
/// transaction; the seed-equivalence test drives it inside its own rolled-back
/// transaction so nothing commits (the same isolation the operation tests use).
/// Returns the number of commands replayed.
pub fn replay_in(conn: pog.Connection, actor: String) -> Result(Int, String) {
  use _ <- result.try(register_clients(conn))
  use _ <- result.try(establish_rate_card(conn))
  let to_apply = commands()
  use _ <- result.try(
    list.try_each(to_apply, fn(command) {
      command.dispatch_in(conn, actor, command)
      |> result.map_error(fn(error) {
        "dispatching "
        <> command.operation_tag(command)
        <> ": "
        <> string.inspect(error)
      })
    }),
  )
  Ok(list.length(to_apply))
}

// --- the founding narrative -------------------------------------------------

/// The ordered founding operations (PRD §7 seed narrative). Replayed through
/// `command.dispatch`, these reconstruct the company state the v1 fixture
/// (`003_seed.sql` + `010`) produces, exercising every write pattern and writing
/// the founding history to `event_log`.
///
/// Ids are the deterministic minted ids on a clean schema (engineers 1/2/3 by
/// onboarding order; projects 1/2/3 by creation order — Ledger Migration, Inventory
/// Sync, Data Platform — under contracts 1/2).
pub fn commands() -> List(Command) {
  [
    // --- onboarding (engineers 1, 2, 3 minted in this order) ---
    // Priya: L5 throughout, from 2024-01-01.
    OnboardEngineer(
      name: "Priya Sharma",
      level: 5,
      effective: Date(2024, January, 1),
    ),
    // Marcus: hired at L4 from 2024-06-01 (promoted to L5 mid-2026, below).
    OnboardEngineer(
      name: "Marcus Chen",
      level: 4,
      effective: Date(2024, June, 1),
    ),
    // Aisha: L6 throughout, from 2025-01-01.
    OnboardEngineer(
      name: "Aisha Okafor",
      level: 6,
      effective: Date(2025, January, 1),
    ),

    // --- client engagements (contracts 1, 2 minted in this order) ---
    SignContract(
      client: "Northwind Trading",
      valid_from: Date(2024, January, 1),
      valid_to: Date(2027, January, 1),
    ),
    SignContract(
      client: "Globex Corporation",
      valid_from: Date(2025, January, 1),
      valid_to: Date(2027, January, 1),
    ),

    // --- projects (1, 2, 3 minted in this order; ⊂ their contract's term) ---
    StartProject(
      name: "Ledger Migration",
      contract_id: 1,
      valid_from: Date(2024, January, 1),
      valid_to: Date(2027, January, 1),
    ),
    StartProject(
      name: "Inventory Sync",
      contract_id: 1,
      valid_from: Date(2025, June, 1),
      valid_to: Date(2027, January, 1),
    ),
    StartProject(
      name: "Data Platform",
      contract_id: 2,
      valid_from: Date(2025, January, 1),
      valid_to: Date(2027, January, 1),
    ),

    // --- allocations (each over [from, 2027-01-01), within its project) ---
    // Priya — the fractional split: 0.5 on Ledger Migration AND 0.5 on Inventory.
    AssignToProject(
      engineer_id: 1,
      project_id: 1,
      fraction: 0.5,
      valid_from: Date(2024, January, 1),
      valid_to: Date(2027, January, 1),
    ),
    AssignToProject(
      engineer_id: 1,
      project_id: 2,
      fraction: 0.5,
      valid_from: Date(2025, June, 1),
      valid_to: Date(2027, January, 1),
    ),
    // Marcus & Aisha — full-time on Data Platform from its start.
    AssignToProject(
      engineer_id: 2,
      project_id: 3,
      fraction: 1.0,
      valid_from: Date(2025, January, 1),
      valid_to: Date(2027, January, 1),
    ),
    AssignToProject(
      engineer_id: 3,
      project_id: 3,
      fraction: 1.0,
      valid_from: Date(2025, January, 1),
      valid_to: Date(2027, January, 1),
    ),

    // --- the mid-2026 rate-card revision (Change; splits the L5 baseline) ---
    // L5 day-rate steps up 1200 -> 1400 from 2026-07-01.
    ReviseRateCard(level: 5, day_rate: 1400.0, effective: Date(2026, July, 1)),

    // --- the future-dated promotion (Change; activates when the slider crosses) -
    // Marcus L4 -> L5 from 2026-07-01: level AND charge rate step up unaided.
    Promote(engineer_id: 2, level: 5, effective: Date(2026, July, 1)),

    // --- leave overlapping an allocation (suppressed in the board read model) ---
    // Aisha on annual leave across the seed "now" (2026-06-15).
    TakeLeave(
      engineer_id: 3,
      kind: "annual",
      valid_from: Date(2026, June, 8),
      valid_to: Date(2026, June, 22),
    ),

    // --- the seeded timesheet (covered by both of Priya's allocations) ---
    LogTimesheet(
      engineer_id: 1,
      project_id: 1,
      day: Date(2026, June, 9),
      hours: 4.0,
    ),
    LogTimesheet(
      engineer_id: 1,
      project_id: 2,
      day: Date(2026, June, 9),
      hours: 4.0,
    ),
  ]
}

// --- bootstrap identity -----------------------------------------------------

/// Register the founding client roster (the durable identity rows `sign_contract`
/// resolves by name). Like `engineer`, `client` is an identity table with no
/// "create" operation — `sign_contract` carries a client by NAME and resolves it
/// to an existing id — so the roster is bootstrap state, exactly as `003_seed.sql`
/// inserts it: Northwind Trading and Globex Corporation.
fn register_clients(db: pog.Connection) -> Result(Nil, String) {
  ["Northwind Trading", "Globex Corporation"]
  |> list.try_each(fn(name) {
    pog.query("INSERT INTO client (name) VALUES ($1)")
    |> pog.parameter(pog.text(name))
    |> pog.execute(on: db)
    |> result.map(fn(_) { Nil })
    |> result.map_error(fn(error) {
      "registering client " <> name <> ": " <> string.inspect(error)
    })
  })
}

// --- rate-card baseline -----------------------------------------------------

/// Establish the founding rate card directly (the bootstrap state every "revise"
/// presupposes). One open-ended row per level from 2024-01-01, matching
/// `003_seed.sql`'s founding rates: L3 800, L4 1000, L5 1200, L6 1800. The genuine
/// L5 step-up is a `ReviseRateCard` command (`commands()`); this just lays the
/// baseline it revises. Ranges are built in SQL so only scalars cross the boundary.
fn establish_rate_card(db: pog.Connection) -> Result(Nil, String) {
  [#(3, 800.0), #(4, 1000.0), #(5, 1200.0), #(6, 1800.0)]
  |> list.try_each(fn(level_rate) {
    let #(level, day_rate) = level_rate
    pog.query(
      "INSERT INTO rate_card (level, day_rate, effective_during)
       VALUES ($1, $2, daterange('2024-01-01', NULL, '[)'))",
    )
    |> pog.parameter(pog.int(level))
    |> pog.parameter(pog.float(day_rate))
    |> pog.execute(on: db)
    |> result.map(fn(_) { Nil })
    |> result.map_error(fn(error) {
      "establishing L"
      <> string.inspect(level)
      <> " rate: "
      <> string.inspect(error)
    })
  })
}

// --- clean migrated reset ---------------------------------------------------

/// Reset the database to a clean migrated (v2) schema: drop and recreate `public`
/// (clearing prior state and the migrate ledger), recreate the ledger, then apply
/// every migration EXCEPT `003_seed.sql` — 001_init, 002_facts, 010_split_allocation,
/// 011_event_log — in order, recording each. The result is the migrated schema with
/// no founding data, ready for the replayed operations to populate. `003_seed.sql`
/// is deliberately skipped: it is the oracle's v1 fixture and must stay unrun here.
fn reset_to_clean_v2(db: pog.Connection) -> Result(Nil, String) {
  use _ <- result.try(reset_public_schema(db))
  use _ <- result.try(ensure_ledger(db))
  [
    "001_init.sql", "002_facts.sql", "010_split_allocation.sql",
    "011_event_log.sql",
  ]
  |> list.try_each(fn(version) { apply_recorded(db, version) })
}

/// Tear down everything in `public` and recreate the empty schema.
fn reset_public_schema(db: pog.Connection) -> Result(Nil, String) {
  ["DROP SCHEMA public CASCADE", "CREATE SCHEMA public"]
  |> list.try_each(fn(statement) { execute(db, statement) })
}

/// Recreate the migrate runner's `schema_migrations` ledger (dropped with the
/// schema), so the DB ends in the same state `gleam run -m tempo/migrate` leaves.
fn ensure_ledger(db: pog.Connection) -> Result(Nil, String) {
  execute(
    db,
    "CREATE TABLE schema_migrations (
       version text PRIMARY KEY,
       applied_at timestamptz NOT NULL DEFAULT now()
     )",
  )
}

/// Apply a migration file from `priv/migrations` and record its version, all in one
/// transaction (a failing statement rolls the file back). Mirrors
/// `tempo/server/migrate`'s per-file semantics.
fn apply_recorded(db: pog.Connection, version: String) -> Result(Nil, String) {
  use body <- result.try(read_priv_sql("migrations/" <> version))
  let statements = migrate.split_statements(body)
  pog.transaction(db, fn(conn) {
    use _ <- result.try(
      list.try_each(statements, fn(statement) {
        pog.query(statement)
        |> pog.execute(on: conn)
        |> result.map(fn(_) { Nil })
      }),
    )
    pog.query("INSERT INTO schema_migrations (version) VALUES ($1)")
    |> pog.parameter(pog.text(version))
    |> pog.execute(on: conn)
    |> result.map(fn(_) { Nil })
  })
  |> result.map(fn(_) { Nil })
  |> result.map_error(fn(error) {
    "applying " <> version <> ": " <> string.inspect(error)
  })
}

/// Read a file under the `tempo` package `priv/` directory as raw text.
fn read_priv_sql(relative_path: String) -> Result(String, String) {
  use priv <- result.try(
    application.priv_directory("tempo")
    |> result.replace_error("priv directory not found"),
  )
  simplifile_read(priv <> "/" <> relative_path)
}

/// Read a file's text, mapping any error to a readable string.
fn simplifile_read(path: String) -> Result(String, String) {
  simplifile.read(path)
  |> result.map_error(fn(error) {
    "reading " <> path <> ": " <> string.inspect(error)
  })
}

/// Run one statement against the pool, mapping any error to a readable string.
fn execute(db: pog.Connection, statement: String) -> Result(Nil, String) {
  pog.query(statement)
  |> pog.execute(on: db)
  |> result.map(fn(_) { Nil })
  |> result.map_error(fn(error) {
    "running `" <> statement <> "`: " <> string.inspect(error)
  })
}
