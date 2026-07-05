import gleam/dynamic/decode
import gleam/time/calendar.{Date, July}
import pog
import tempo/server/fact.{EngineerId, WorkDayCleared}
import tempo/server/repository
import test_pool

fn rolling_back(body: fn(pog.Connection) -> a) -> a {
  let assert Error(pog.TransactionRolledBack(value)) =
    pog.transaction(test_pool.db(), fn(conn) { Error(body(conn)) })
  value
}

fn insert_engineer(conn: pog.Connection) -> Int {
  let row = {
    use id <- decode.field(0, decode.int)
    decode.success(id)
  }
  let assert Ok(returned) =
    pog.query("INSERT INTO engineer DEFAULT VALUES RETURNING id")
    |> pog.returning(row)
    |> pog.execute(on: conn)
  let assert [id, ..] = returned.rows
  id
}

pub fn clearing_an_empty_weekday_succeeds_test() {
  use conn <- rolling_back()
  let engineer_id = insert_engineer(conn)
  let outcome =
    repository.write(
      conn,
      1,
      WorkDayCleared(
        engineer_id: EngineerId(engineer_id),
        weekday: 4,
        from: Date(2026, July, 1),
      ),
    )
  assert outcome == Ok(Nil)
}
