//// Layer-3 seed-equivalence test (ADR-023, PRD §9.3). The operation-built seed
//// (`tempo/seed`) must produce the SAME board as the intended founding data — so
//// "seed-as-operations == the data the migrate+seed path produces." This is the
//// mini-oracle for the write model: if replaying the founding operations drifts
//// from the canonical fixture on any date, the board diverges and this fails.
////
//// THE REFERENCE is the board the shared migrate+seed database already holds — the
//// v1 fixture (`003_seed.sql`) coalesced onto the v2 schema by `010`, the canonical
//// founding data the read-only tests also assert against.
//// THE SUBJECT is the board after replaying the founding `Command`s
//// (`seed.replay_in`) onto the same v2 schema. Both are snapshotted across a DENSE
//// date range (every day in the seed span) with the EXACT board-snapshot machinery
//// the migration oracle uses (`oracle.board_snapshot_sql` / `oracle.snapshot`),
//// then compared date-by-date with `oracle.first_mismatch`. The rendering excludes
//// the engagement window and ids (which legitimately differ between the two paths)
//// and compares the user-visible board: engineer, level, project, client, fraction,
//// charge rate.
////
//// DB ISOLATION (consistent with the operation tests). The subject board is built
//// inside the test's OWN transaction, which is ROLLED BACK — the snapshot is
//// smuggled out via `TransactionRolledBack`, exactly the pattern operations_test /
//// sql_test use. Inside that transaction the fact/identity/journal tables are
//// truncated (transactional, so the rollback restores them) and the founding
//// operations replayed on the open connection (`dispatch_in`). Nothing commits, so
//// the shared seed the other tests depend on is never disturbed and there is no
//// race with the concurrent gleeunit runner.

import gleam/erlang/process
import gleam/list
import pog
import tempo/oracle
import tempo/seed
import tempo/server/context

// --- connection -------------------------------------------------------------

/// A single-connection pool for the test. One connection suffices — the test owns
/// one rolled-back transaction — and a tiny pool avoids exhausting PG's
/// max_connections across the concurrent gleeunit runner.
fn db() -> pog.Connection {
  let pool_name = process.new_name(prefix: "tempo_seed_equivalence_test_db")
  let config =
    context.pool_config(context.settings_from_env(), pool_name)
    |> pog.pool_size(1)
  let assert Ok(started) = pog.start(config)
  started.data
}

// --- the equivalence proof --------------------------------------------------

// Replaying the founding operations reconstructs the canonical board: for every
// day in the seed span the operation-built board equals the migrate+seed board.
pub fn operation_seed_board_matches_migrate_seed_board_test() {
  let connection = db()
  let dates = oracle.seed_span_dates(connection)
  let snapshot_sql = oracle.board_snapshot_sql()

  // Reference: the board the shared migrate+seed DB already holds (read-only).
  let reference = oracle.snapshot(connection, snapshot_sql, dates)

  // Subject: clear the facts, replay the founding operations, snapshot the board —
  // all inside one transaction that is rolled back, so the shared seed is intact.
  let actual =
    rolling_back(connection, fn(conn) {
      clear_all(conn)
      let assert Ok(_count) = seed.replay_in(conn, "seed")
      oracle.snapshot(conn, snapshot_sql, dates)
    })

  // The dense range really is dense (every day in the seed span), and the two
  // boards agree on all of them.
  assert list.length(dates) > 1000
  assert oracle.first_mismatch(reference, actual) == Error(Nil)
}

// --- rollback harness -------------------------------------------------------

/// Run `body` inside a transaction, then roll back, smuggling its return value out
/// through `TransactionRolledBack` (the operations_test / sql_test isolation
/// pattern) so nothing the body did — the truncate or the replayed operations — is
/// ever committed.
fn rolling_back(
  connection: pog.Connection,
  body: fn(pog.Connection) -> a,
) -> a {
  let outcome = pog.transaction(connection, fn(conn) { Error(body(conn)) })
  let assert Error(pog.TransactionRolledBack(value)) = outcome
  value
}

/// Empty every fact, identity, and journal table and RESTART their identity
/// sequences, so the replayed operations mint engineers/contracts/projects from 1
/// exactly as on a clean schema. Transactional, so the test's rollback restores the
/// shared seed. CASCADE clears the PERIOD-FK-linked rows together.
fn clear_all(conn: pog.Connection) -> Nil {
  let assert Ok(_) =
    pog.query(
      "TRUNCATE timesheet, allocation, leave, engineer_role, employment,
                project, contract, rate_card, engineer, client, event_log
       RESTART IDENTITY CASCADE",
    )
    |> pog.execute(on: conn)
  Nil
}
