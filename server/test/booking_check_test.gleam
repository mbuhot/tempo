import gleam/dynamic/decode
import gleam/option.{None}
import gleam/result
import gleam/time/calendar.{Date, June}
import pog
import shared/command as gateway
import shared/meeting/command.{AllowOverlap, Optional, RequireFree, Required} as meeting_command
import tempo/server/command
import tempo/server/operation
import test_pool

fn rolling_back(body: fn(pog.Connection) -> a) -> a {
  let assert Error(pog.TransactionRolledBack(value)) =
    pog.transaction(test_pool.db(), fn(conn) { Error(body(conn)) })
  value
}

fn meeting_id_by_title(conn: pog.Connection, title: String) -> Int {
  let row = {
    use meeting_id <- decode.field(0, decode.int)
    decode.success(meeting_id)
  }
  let assert Ok(returned) =
    pog.query("SELECT meeting_id FROM meeting_subject WHERE title = $1")
    |> pog.parameter(pog.text(title))
    |> pog.returning(row)
    |> pog.execute(on: conn)
  let assert [meeting_id] = returned.rows
  meeting_id
}

fn open_booking_count(conn: pog.Connection, meeting_id: Int) -> Int {
  let row = {
    use count <- decode.field(0, decode.int)
    decode.success(count)
  }
  let assert Ok(returned) =
    pog.query(
      "SELECT count(*) FROM meeting_booking WHERE meeting_id = $1 AND upper_inf(booked_during)",
    )
    |> pog.parameter(pog.int(meeting_id))
    |> pog.returning(row)
    |> pog.execute(on: conn)
  let assert [count] = returned.rows
  count
}

/// Build a `ScheduleMeeting` fixed to no location/client/project, varying only
/// the window, attendees, and `check` — the three axes this suite exercises.
fn schedule_command(
  title title: String,
  date date: calendar.Date,
  starts_at starts_at: String,
  duration_minutes duration_minutes: Int,
  timezone timezone: String,
  attendees attendees: List(#(Int, meeting_command.Attendance)),
  check check: meeting_command.BookingCheck,
) -> gateway.Command {
  gateway.MeetingCommand(meeting_command.ScheduleMeeting(
    title:,
    timezone:,
    date:,
    starts_at:,
    duration_minutes:,
    location: None,
    client_id: None,
    project_id: None,
    attendees:,
    check:,
  ))
}

pub fn require_free_schedule_into_a_free_slot_succeeds_test() {
  rolling_back(fn(conn) {
    let assert Ok(_) =
      command.dispatch_in(
        conn,
        "tester",
        schedule_command(
          title: "Free slot booking",
          date: Date(2026, June, 23),
          starts_at: "09:00",
          duration_minutes: 60,
          timezone: "America/Los_Angeles",
          attendees: [#(2, Required)],
          check: RequireFree,
        ),
      )
    let meeting_id = meeting_id_by_title(conn, "Free slot booking")
    assert open_booking_count(conn, meeting_id) == 1
  })
}

pub fn require_free_is_rejected_by_an_existing_overlap_test() {
  rolling_back(fn(conn) {
    let assert Ok(_) =
      command.dispatch_in(
        conn,
        "tester",
        schedule_command(
          title: "Existing overlap",
          date: Date(2026, June, 23),
          starts_at: "10:00",
          duration_minutes: 60,
          timezone: "America/Los_Angeles",
          attendees: [#(2, Required)],
          check: AllowOverlap,
        ),
      )
    let outcome =
      command.dispatch_in(
        conn,
        "tester",
        schedule_command(
          title: "Should be blocked",
          date: Date(2026, June, 23),
          starts_at: "10:00",
          duration_minutes: 60,
          timezone: "America/Los_Angeles",
          attendees: [#(2, Required)],
          check: RequireFree,
        ),
      )
    assert outcome == Error(operation.SlotTaken)
  })
}

pub fn allow_overlap_still_books_the_same_colliding_window_test() {
  rolling_back(fn(conn) {
    let assert Ok(_) =
      command.dispatch_in(
        conn,
        "tester",
        schedule_command(
          title: "Existing overlap",
          date: Date(2026, June, 23),
          starts_at: "10:00",
          duration_minutes: 60,
          timezone: "America/Los_Angeles",
          attendees: [#(2, Required)],
          check: AllowOverlap,
        ),
      )
    let outcome =
      command.dispatch_in(
        conn,
        "tester",
        schedule_command(
          title: "Overlap allowed",
          date: Date(2026, June, 23),
          starts_at: "10:00",
          duration_minutes: 60,
          timezone: "America/Los_Angeles",
          attendees: [#(2, Required)],
          check: AllowOverlap,
        ),
      )
    assert outcome |> result.is_ok
  })
}

pub fn require_free_over_a_focus_block_fails_test() {
  rolling_back(fn(conn) {
    let outcome =
      command.dispatch_in(
        conn,
        "tester",
        schedule_command(
          title: "Into the focus block",
          date: Date(2026, June, 22),
          starts_at: "13:30",
          duration_minutes: 30,
          timezone: "America/Los_Angeles",
          attendees: [#(2, Required)],
          check: RequireFree,
        ),
      )
    assert outcome == Error(operation.SlotTaken)
  })
}

pub fn require_free_outside_working_hours_fails_test() {
  rolling_back(fn(conn) {
    let outcome =
      command.dispatch_in(
        conn,
        "tester",
        schedule_command(
          title: "After hours",
          date: Date(2026, June, 23),
          starts_at: "20:00",
          duration_minutes: 60,
          timezone: "America/Los_Angeles",
          attendees: [#(2, Required)],
          check: RequireFree,
        ),
      )
    assert outcome == Error(operation.SlotTaken)
  })
}

pub fn require_free_on_a_leave_day_fails_test() {
  rolling_back(fn(conn) {
    let outcome =
      command.dispatch_in(
        conn,
        "tester",
        schedule_command(
          title: "During leave",
          date: Date(2026, June, 16),
          starts_at: "10:00",
          duration_minutes: 60,
          timezone: "Europe/London",
          attendees: [#(3, Required)],
          check: RequireFree,
        ),
      )
    assert outcome == Error(operation.SlotTaken)
  })
}

pub fn require_free_does_not_gate_on_a_busy_optional_attendee_test() {
  rolling_back(fn(conn) {
    let outcome =
      command.dispatch_in(
        conn,
        "tester",
        schedule_command(
          title: "Optional rides along",
          date: Date(2026, June, 22),
          starts_at: "13:30",
          duration_minutes: 30,
          timezone: "America/Los_Angeles",
          attendees: [#(2, Optional)],
          check: RequireFree,
        ),
      )
    assert outcome |> result.is_ok
  })
}

pub fn require_free_reschedule_onto_its_own_window_succeeds_test() {
  rolling_back(fn(conn) {
    let assert Ok(_) =
      command.dispatch_in(
        conn,
        "tester",
        schedule_command(
          title: "Reschedule self",
          date: Date(2026, June, 23),
          starts_at: "09:00",
          duration_minutes: 60,
          timezone: "America/Los_Angeles",
          attendees: [#(2, Required)],
          check: AllowOverlap,
        ),
      )
    let meeting_id = meeting_id_by_title(conn, "Reschedule self")
    let outcome =
      command.dispatch_in(
        conn,
        "tester",
        gateway.MeetingCommand(meeting_command.RescheduleMeeting(
          meeting_id:,
          timezone: "America/Los_Angeles",
          date: Date(2026, June, 23),
          starts_at: "09:00",
          duration_minutes: 60,
          check: RequireFree,
        )),
      )
    assert outcome |> result.is_ok
  })
}

pub fn require_free_reschedule_onto_a_different_meetings_window_fails_test() {
  rolling_back(fn(conn) {
    let assert Ok(_) =
      command.dispatch_in(
        conn,
        "tester",
        schedule_command(
          title: "First meeting",
          date: Date(2026, June, 23),
          starts_at: "09:00",
          duration_minutes: 60,
          timezone: "America/Los_Angeles",
          attendees: [#(2, Required)],
          check: AllowOverlap,
        ),
      )
    let first_meeting_id = meeting_id_by_title(conn, "First meeting")
    let assert Ok(_) =
      command.dispatch_in(
        conn,
        "tester",
        schedule_command(
          title: "Second meeting",
          date: Date(2026, June, 24),
          starts_at: "09:00",
          duration_minutes: 60,
          timezone: "America/Los_Angeles",
          attendees: [#(2, Required)],
          check: AllowOverlap,
        ),
      )
    let outcome =
      command.dispatch_in(
        conn,
        "tester",
        gateway.MeetingCommand(meeting_command.RescheduleMeeting(
          meeting_id: first_meeting_id,
          timezone: "America/Los_Angeles",
          date: Date(2026, June, 24),
          starts_at: "09:00",
          duration_minutes: 60,
          check: RequireFree,
        )),
      )
    assert outcome == Error(operation.SlotTaken)
  })
}
