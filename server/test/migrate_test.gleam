import gleam/list
import tempo/server/context
import tempo/server/migrate

// --- split_statements (pure; no DB) -----------------------------------------

pub fn split_single_statement_test() {
  let statements = migrate.split_statements("CREATE TABLE t (x int);")

  assert statements == ["CREATE TABLE t (x int);"]
}

pub fn split_drops_trailing_whitespace_only_chunk_test() {
  let statements = migrate.split_statements("SELECT 1;\n\n")

  assert statements == ["SELECT 1;"]
}

pub fn split_two_statements_test() {
  let statements =
    migrate.split_statements("CREATE TABLE a (x int);\nCREATE TABLE b (y int);")

  assert statements == ["CREATE TABLE a (x int);", "CREATE TABLE b (y int);"]
}

pub fn split_ignores_semicolon_in_single_quoted_string_test() {
  let statements =
    migrate.split_statements("INSERT INTO t VALUES ('a;b'); SELECT 1;")

  assert statements == ["INSERT INTO t VALUES ('a;b');", "SELECT 1;"]
}

pub fn split_ignores_semicolon_in_dollar_quoted_block_test() {
  let sql = "DO $$ BEGIN PERFORM 1; PERFORM 2; END $$; SELECT 3;"
  let statements = migrate.split_statements(sql)

  assert statements
    == ["DO $$ BEGIN PERFORM 1; PERFORM 2; END $$;", "SELECT 3;"]
}

pub fn split_ignores_semicolon_in_line_comment_test() {
  let sql = "SELECT 1; -- a comment with ; in it\nSELECT 2;"
  let statements = migrate.split_statements(sql)

  assert statements == ["SELECT 1;", "-- a comment with ; in it\nSELECT 2;"]
}

// --- run (requires PG19 on port 5434) ---------------------------------------

// Re-running an up-to-date migration set applies nothing: the second run reports
// the same versions as already-applied and an empty applied list.
pub fn run_is_idempotent_test() {
  let assert Ok(ctx) = context.start()

  let assert Ok(first) = migrate.run(ctx)
  let assert Ok(second) = migrate.run(ctx)

  // Whatever exists on disk, the second pass applies nothing new and reports
  // every version as already applied.
  assert second.applied == []
  assert second.already_applied
    == list.append(first.applied, first.already_applied)
}
