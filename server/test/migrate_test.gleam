import gleam/dynamic/decode
import gleam/list
import pog
import tempo/server/migrate
import test_pool

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
  let ctx = test_pool.ctx()

  let assert Ok(first) = migrate.run(ctx)
  let assert Ok(second) = migrate.run(ctx)

  // Whatever exists on disk, the second pass applies nothing new and reports
  // every version as already applied.
  assert second.applied == []
  assert second.already_applied
    == list.append(first.applied, first.already_applied)
}

// The performance-index migration gives the two snapshot line tables a real
// surrogate primary key (they shipped as PK-less heaps). A fully-migrated DB
// has exactly one PRIMARY KEY index on each.
pub fn line_tables_have_surrogate_primary_keys_test() {
  let assert Ok(_) = migrate.run(test_pool.ctx())

  assert primary_key_index("invoice_line") == "invoice_line_pkey"
  assert primary_key_index("payroll_line") == "payroll_line_pkey"
}

// The same migration adds GiST indexes on the semantic-period range columns the
// as-of joins probe with @>/&&. A fully-migrated DB has them on disk.
pub fn as_of_range_columns_have_gist_indexes_test() {
  let assert Ok(_) = migrate.run(test_pool.ctx())

  assert has_index("allocation_allocated_during_gist") == True
  assert has_index("employment_employed_during_gist") == True
  assert has_index("engineer_role_held_during_gist") == True
  assert has_index("rate_card_effective_during_gist") == True
  assert has_index("salary_effective_during_gist") == True
  assert has_index("project_run_active_during_gist") == True
}

// The capability & skill taxonomy migration (#38) gives each of its four
// temporal tables a named WITHOUT OVERLAPS primary key — an explicitly named
// constraint's underlying index takes the constraint's own name, so a fully
// migrated DB has each `*_no_overlap` name on disk as that table's PK index.
pub fn capabilities_skills_tables_have_named_no_overlap_primary_keys_test() {
  let assert Ok(_) = migrate.run(test_pool.ctx())

  assert primary_key_index("capability_profile")
    == "capability_profile_no_overlap"
  assert primary_key_index("skill_profile") == "skill_profile_no_overlap"
  assert primary_key_index("capability_skill") == "capability_skill_no_overlap"
  assert primary_key_index("engineer_skill") == "engineer_skill_no_overlap"
}

// The same migration adds an audit_id index on each new temporal table, mirroring
// every other fact table's provenance lookup.
pub fn capabilities_skills_tables_have_audit_id_indexes_test() {
  let assert Ok(_) = migrate.run(test_pool.ctx())

  assert has_index("capability_profile_audit_id_idx") == True
  assert has_index("skill_profile_audit_id_idx") == True
  assert has_index("capability_skill_audit_id_idx") == True
  assert has_index("engineer_skill_audit_id_idx") == True
}

/// The name of the PRIMARY KEY index on `table`, read from the catalog.
fn primary_key_index(table: String) -> String {
  let row_decoder = {
    use name <- decode.field(0, decode.string)
    decode.success(name)
  }
  let assert Ok(returned) =
    pog.query(
      "SELECT i.relname
         FROM pg_index x
         JOIN pg_class c ON c.oid = x.indrelid
         JOIN pg_class i ON i.oid = x.indexrelid
        WHERE c.relname = $1 AND x.indisprimary",
    )
    |> pog.parameter(pog.text(table))
    |> pog.returning(row_decoder)
    |> pog.execute(on: test_pool.db())
  let assert [name] = returned.rows
  name
}

/// Whether an index of the given name exists in the public schema.
fn has_index(name: String) -> Bool {
  let row_decoder = {
    use count <- decode.field(0, decode.int)
    decode.success(count)
  }
  let assert Ok(returned) =
    pog.query(
      "SELECT count(*)::int FROM pg_indexes
        WHERE schemaname = 'public' AND indexname = $1",
    )
    |> pog.parameter(pog.text(name))
    |> pog.returning(row_decoder)
    |> pog.execute(on: test_pool.db())
  let assert [count] = returned.rows
  count == 1
}
