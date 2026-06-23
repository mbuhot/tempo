import tempo/seed
import test_pool

// A non-dev environment is refused before any DB work: seeding a real
// environment is impossible by default.
pub fn seed_refuses_non_dev_environment_test() {
  let ctx = test_pool.ctx()

  let result = seed.run(ctx, "production")

  assert result == Error(seed.NotDevEnvironment("production"))
}

// The test DB is already migrated + seeded, so a dev seed run finds the cast
// present and is a no-op rather than a double-insert.
pub fn seed_is_noop_on_already_seeded_db_test() {
  let ctx = test_pool.ctx()

  let result = seed.run(ctx, "dev")

  assert result == Ok(seed.AlreadySeeded)
}
