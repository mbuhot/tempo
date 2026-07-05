import gleam/dynamic/decode
import pog
import tempo/server/fact.{MeetingAttendeeAdded, MeetingId}
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

pub fn create_meeting_mints_a_positive_id_and_records_an_attendee_test() {
  rolling_back(fn(conn) {
    let engineer_id = insert_engineer(conn)
    let assert Ok(MeetingId(meeting_id)) = repository.create_meeting(conn)
    assert meeting_id > 0

    let outcome =
      repository.write(
        conn,
        1,
        MeetingAttendeeAdded(
          meeting_id: MeetingId(meeting_id),
          engineer_id:,
          attendance: "required",
        ),
      )
    assert outcome == Ok(Nil)
  })
}
