import concurrency_pool
import gleeunit
import serial_pool
import tempo/server/context
import test_pool

pub fn main() -> Nil {
  test_pool.start()
  concurrency_pool.start()
  serial_pool.start()
  gleeunit.main()
}

// The shared pool connects to the docker-compose PG19 instance and answers a
// trivial query. Requires `docker compose up` (the DB on port 5434). This is the
// foundation smoke check for every later DB test.
pub fn pool_smoke_check_test() {
  let assert Ok(answer) = context.smoke_check(test_pool.db())

  assert answer == 1
}
