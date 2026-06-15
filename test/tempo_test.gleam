import gleeunit
import tempo/server/context

pub fn main() -> Nil {
  gleeunit.main()
}

// The pool connects to the docker-compose PG19 instance and answers a trivial
// query. Requires `docker compose up` (the DB on port 5434). This is the
// foundation smoke check for every later DB test.
pub fn pool_smoke_check_test() {
  let assert Ok(ctx) = context.start()
  let assert Ok(answer) = context.smoke_check(ctx.db)

  assert answer == 1
}
