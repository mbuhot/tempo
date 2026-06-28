import gleam/dynamic/decode
import pog
import tempo/server/migrate
import test_pool

// A fully-migrated DB has the two workflow draft tables (#28): the instance anchor
// and its append-only transaction-time step values.
pub fn workflow_tables_exist_test() {
  let assert Ok(_) = migrate.run(test_pool.ctx())

  assert table_exists("workflow_instance") == True
  assert table_exists("workflow_step_value") == True
}

/// Whether a base table of the given name exists in the public schema.
fn table_exists(name: String) -> Bool {
  let row_decoder = {
    use count <- decode.field(0, decode.int)
    decode.success(count)
  }
  let assert Ok(returned) =
    pog.query(
      "SELECT count(*)::int FROM information_schema.tables
        WHERE table_schema = 'public' AND table_name = $1",
    )
    |> pog.parameter(pog.text(name))
    |> pog.returning(row_decoder)
    |> pog.execute(on: test_pool.db())
  let assert [count] = returned.rows
  count == 1
}
