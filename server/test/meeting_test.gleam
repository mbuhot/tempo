import gleam/dynamic/decode
import gleam/option.{None, Some}
import gleam/time/calendar.{Date, July}
import pog
import shared/command as gateway
import shared/meeting/command.{Optional, Required} as meeting_command
import tempo/server/command
import tempo/server/fact.{MeetingAttendeeAdded, MeetingId}
import tempo/server/operation
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

fn meeting_id_by_title(conn: pog.Connection, title: String) -> Int {
  let row = {
    use meeting_id <- decode.field(0, decode.int)
    decode.success(meeting_id)
  }
  let assert Ok(returned) =
    pog.query("SELECT meeting_id FROM meeting_detail WHERE title = $1")
    |> pog.parameter(pog.text(title))
    |> pog.returning(row)
    |> pog.execute(on: conn)
  let assert [meeting_id] = returned.rows
  meeting_id
}

fn meeting_status(conn: pog.Connection, meeting_id: Int) -> String {
  let row = {
    use status <- decode.field(0, decode.string)
    decode.success(status)
  }
  let assert Ok(returned) =
    pog.query("SELECT status FROM meeting_detail WHERE meeting_id = $1")
    |> pog.parameter(pog.int(meeting_id))
    |> pog.returning(row)
    |> pog.execute(on: conn)
  let assert [status] = returned.rows
  status
}

fn meeting_audit_id(conn: pog.Connection, meeting_id: Int) -> Int {
  let row = {
    use audit_id <- decode.field(0, decode.int)
    decode.success(audit_id)
  }
  let assert Ok(returned) =
    pog.query("SELECT audit_id FROM meeting_detail WHERE meeting_id = $1")
    |> pog.parameter(pog.int(meeting_id))
    |> pog.returning(row)
    |> pog.execute(on: conn)
  let assert [audit_id] = returned.rows
  audit_id
}

fn meeting_local_starts_at(
  conn: pog.Connection,
  meeting_id: Int,
  timezone: String,
) -> String {
  let row = {
    use starts_at <- decode.field(0, decode.string)
    decode.success(starts_at)
  }
  let assert Ok(returned) =
    pog.query(
      "SELECT to_char(lower(meeting_at) AT TIME ZONE $2, 'HH24:MI') FROM meeting_detail WHERE meeting_id = $1",
    )
    |> pog.parameter(pog.int(meeting_id))
    |> pog.parameter(pog.text(timezone))
    |> pog.returning(row)
    |> pog.execute(on: conn)
  let assert [starts_at] = returned.rows
  starts_at
}

fn attendee_count(conn: pog.Connection, meeting_id: Int) -> Int {
  let row = {
    use count <- decode.field(0, decode.int)
    decode.success(count)
  }
  let assert Ok(returned) =
    pog.query("SELECT count(*) FROM meeting_attendee WHERE meeting_id = $1")
    |> pog.parameter(pog.int(meeting_id))
    |> pog.returning(row)
    |> pog.execute(on: conn)
  let assert [count] = returned.rows
  count
}

pub fn schedule_meeting_records_detail_and_attendees_test() {
  rolling_back(fn(conn) {
    let alice = insert_engineer(conn)
    let bob = insert_engineer(conn)
    let assert Ok(_) =
      command.dispatch_in(
        conn,
        "tester",
        gateway.MeetingCommand(
          meeting_command.ScheduleMeeting(
            title: "Design review",
            timezone: "Europe/London",
            date: Date(2026, July, 10),
            starts_at: "09:00",
            duration_minutes: 60,
            location: Some("https://meet.example/xyz"),
            client_id: None,
            project_id: None,
            attendees: [#(alice, Required), #(bob, Optional)],
          ),
        ),
      )
    let meeting_id = meeting_id_by_title(conn, "Design review")
    assert meeting_status(conn, meeting_id) == "scheduled"
    assert meeting_local_starts_at(conn, meeting_id, "Europe/London") == "09:00"
    assert meeting_audit_id(conn, meeting_id) > 0
    assert attendee_count(conn, meeting_id) == 2
  })
}

pub fn reschedule_meeting_moves_the_start_time_test() {
  rolling_back(fn(conn) {
    let engineer_id = insert_engineer(conn)
    let assert Ok(_) =
      command.dispatch_in(
        conn,
        "tester",
        gateway.MeetingCommand(
          meeting_command.ScheduleMeeting(
            title: "Sprint planning",
            timezone: "Europe/London",
            date: Date(2026, July, 10),
            starts_at: "09:00",
            duration_minutes: 60,
            location: None,
            client_id: None,
            project_id: None,
            attendees: [#(engineer_id, Required)],
          ),
        ),
      )
    let meeting_id = meeting_id_by_title(conn, "Sprint planning")
    let assert Ok(_) =
      command.dispatch_in(
        conn,
        "tester",
        gateway.MeetingCommand(meeting_command.RescheduleMeeting(
          meeting_id:,
          timezone: "Europe/London",
          date: Date(2026, July, 11),
          starts_at: "14:30",
          duration_minutes: 30,
        )),
      )
    assert meeting_local_starts_at(conn, meeting_id, "Europe/London") == "14:30"
  })
}

pub fn cancel_meeting_flips_status_test() {
  rolling_back(fn(conn) {
    let engineer_id = insert_engineer(conn)
    let assert Ok(_) =
      command.dispatch_in(
        conn,
        "tester",
        gateway.MeetingCommand(
          meeting_command.ScheduleMeeting(
            title: "Retro",
            timezone: "Europe/London",
            date: Date(2026, July, 10),
            starts_at: "09:00",
            duration_minutes: 60,
            location: None,
            client_id: None,
            project_id: None,
            attendees: [#(engineer_id, Required)],
          ),
        ),
      )
    let meeting_id = meeting_id_by_title(conn, "Retro")
    let assert Ok(_) =
      command.dispatch_in(
        conn,
        "tester",
        gateway.MeetingCommand(meeting_command.CancelMeeting(meeting_id:)),
      )
    assert meeting_status(conn, meeting_id) == "cancelled"
  })
}

pub fn add_then_remove_attendee_changes_the_roster_test() {
  rolling_back(fn(conn) {
    let organizer = insert_engineer(conn)
    let guest = insert_engineer(conn)
    let assert Ok(_) =
      command.dispatch_in(
        conn,
        "tester",
        gateway.MeetingCommand(
          meeting_command.ScheduleMeeting(
            title: "Client sync",
            timezone: "Europe/London",
            date: Date(2026, July, 10),
            starts_at: "09:00",
            duration_minutes: 60,
            location: None,
            client_id: None,
            project_id: None,
            attendees: [#(organizer, Required)],
          ),
        ),
      )
    let meeting_id = meeting_id_by_title(conn, "Client sync")
    assert attendee_count(conn, meeting_id) == 1

    let assert Ok(_) =
      command.dispatch_in(
        conn,
        "tester",
        gateway.MeetingCommand(meeting_command.AddAttendee(
          meeting_id:,
          engineer_id: guest,
          attendance: Optional,
        )),
      )
    assert attendee_count(conn, meeting_id) == 2

    let assert Ok(_) =
      command.dispatch_in(
        conn,
        "tester",
        gateway.MeetingCommand(meeting_command.RemoveAttendee(
          meeting_id:,
          engineer_id: guest,
        )),
      )
    assert attendee_count(conn, meeting_id) == 1
  })
}

pub fn schedule_meeting_rejects_an_unknown_timezone_test() {
  let outcome =
    rolling_back(fn(conn) {
      let engineer_id = insert_engineer(conn)
      command.dispatch_in(
        conn,
        "tester",
        gateway.MeetingCommand(
          meeting_command.ScheduleMeeting(
            title: "Broken zone",
            timezone: "Mars/Olympus_Mons",
            date: Date(2026, July, 10),
            starts_at: "09:00",
            duration_minutes: 60,
            location: None,
            client_id: None,
            project_id: None,
            attendees: [#(engineer_id, Required)],
          ),
        ),
      )
    })
  assert outcome == Error(operation.InvalidValue)
}

pub fn reschedule_a_nonexistent_meeting_is_rejected_test() {
  let outcome =
    rolling_back(fn(conn) {
      command.dispatch_in(
        conn,
        "tester",
        gateway.MeetingCommand(meeting_command.RescheduleMeeting(
          meeting_id: 999_999_999,
          timezone: "Europe/London",
          date: Date(2026, July, 10),
          starts_at: "09:00",
          duration_minutes: 60,
        )),
      )
    })
  assert outcome == Error(operation.NoSuchVersion)
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
