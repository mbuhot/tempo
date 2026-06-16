//// `gleam run -m tempo/migrate` entrypoint (ARCHITECTURE.md §9).
//// The runner lives in `tempo/server/migrate`; this is the short alias the build
//// docs invoke. It just delegates.

import tempo/server/migrate

pub fn main() -> Nil {
  migrate.main()
}
