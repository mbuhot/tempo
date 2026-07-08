import gleam/dynamic/decode
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/time/calendar.{Date}
import pog
import shared/command as gateway
import shared/meeting/command.{Required} as meeting_command
import shared/meeting/view.{type CandidateSlot}
import tempo/server/command
import tempo/server/context
import tempo/server/meeting/view as meeting_view
import test_pool

fn rolling_back(body: fn(pog.Connection) -> a) -> a {
  let assert Error(pog.TransactionRolledBack(value)) =
    pog.transaction(test_pool.db(), fn(conn) { Error(body(conn)) })
  value
}

fn ctx(conn: pog.Connection) -> context.Context {
  context.Context(db: conn, principal: None)
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

fn insert_work_schedule(conn: pog.Connection, engineer_id: Int) -> Nil {
  let assert Ok(logged) =
    pog.query(
      "INSERT INTO event_log (occurred_at, actor, operation, summary, payload) "
      <> "VALUES ('2024-01-01', 'tester', 'test', 'test', '{}') RETURNING id",
    )
    |> pog.returning({
      use id <- decode.field(0, decode.int)
      decode.success(id)
    })
    |> pog.execute(on: conn)
  let assert [audit_id] = logged.rows
  let assert Ok(_) =
    pog.query(
      "INSERT INTO work_schedule (engineer_id, weekday, valid_at, starts, ends, audit_id) "
      <> "SELECT $1, wd, daterange('2024-01-01', NULL, '[)'), '09:00', '17:00', $2 "
      <> "FROM generate_series(0, 4) wd",
    )
    |> pog.parameter(pog.int(engineer_id))
    |> pog.parameter(pog.int(audit_id))
    |> pog.execute(on: conn)
  Nil
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

fn spans(slots: List(CandidateSlot)) -> List(#(String, String)) {
  list.map(slots, fn(slot) { #(slot.starts_at, slot.ends_at) })
}

fn offsets(slot: CandidateSlot) -> List(#(Int, Option(Int))) {
  list.map(slot.attendees, fn(attendee) {
    #(attendee.engineer_id, attendee.offset_minutes)
  })
}

pub fn sydney_and_la_only_share_one_hour_a_day_test() {
  rolling_back(fn(conn) {
    let assert Ok(slots) =
      meeting_view.find_time(
        ctx(conn),
        Date(2026, calendar.June, 15),
        Date(2026, calendar.June, 19),
        "Europe/London",
        60,
        [1, 2],
        [],
        0,
      )
    assert spans(slots)
      == [
        #("2026-06-15T23:00:00Z", "2026-06-16T00:00:00Z"),
        #("2026-06-16T23:00:00Z", "2026-06-17T00:00:00Z"),
        #("2026-06-17T23:00:00Z", "2026-06-18T00:00:00Z"),
        #("2026-06-18T23:00:00Z", "2026-06-19T00:00:00Z"),
      ]
    let assert [first, ..] = slots
    assert offsets(first) == [#(2, Some(-420)), #(1, Some(600))]
  })
}

pub fn relocation_mid_range_pins_each_windows_zone_test() {
  rolling_back(fn(conn) {
    let assert Ok(slots) =
      meeting_view.find_time(
        ctx(conn),
        Date(2026, calendar.June, 29),
        Date(2026, calendar.July, 3),
        "Europe/London",
        480,
        [1],
        [],
        0,
      )
    assert spans(slots)
      == [
        #("2026-06-28T23:00:00Z", "2026-06-29T07:00:00Z"),
        #("2026-06-29T23:00:00Z", "2026-06-30T07:00:00Z"),
        #("2026-07-01T08:00:00Z", "2026-07-01T16:00:00Z"),
        #("2026-07-02T08:00:00Z", "2026-07-02T16:00:00Z"),
      ]
  })
}

pub fn dst_boundary_shifts_the_london_offset_test() {
  rolling_back(fn(conn) {
    let assert Ok(slots) =
      meeting_view.find_time(
        ctx(conn),
        Date(2026, calendar.October, 23),
        Date(2026, calendar.October, 26),
        "Europe/London",
        60,
        [3],
        [],
        0,
      )
    assert spans(slots)
      == [
        #("2026-10-23T08:00:00Z", "2026-10-23T16:00:00Z"),
        #("2026-10-26T09:00:00Z", "2026-10-26T17:00:00Z"),
      ]
  })
}

pub fn leave_blocks_a_required_attendee_for_the_whole_span_test() {
  rolling_back(fn(conn) {
    let assert Ok(slots) =
      meeting_view.find_time(
        ctx(conn),
        Date(2026, calendar.June, 15),
        Date(2026, calendar.June, 19),
        "Europe/London",
        30,
        [1, 3],
        [],
        0,
      )
    assert slots == []
  })
}

pub fn optional_attendee_rides_along_without_narrowing_the_windows_test() {
  rolling_back(fn(conn) {
    let assert Ok(slots) =
      meeting_view.find_time(
        ctx(conn),
        Date(2026, calendar.June, 15),
        Date(2026, calendar.June, 19),
        "Europe/London",
        60,
        [2],
        [3],
        0,
      )
    assert spans(slots)
      == [
        #("2026-06-15T16:00:00Z", "2026-06-16T00:00:00Z"),
        #("2026-06-16T16:00:00Z", "2026-06-17T00:00:00Z"),
        #("2026-06-17T16:00:00Z", "2026-06-18T00:00:00Z"),
        #("2026-06-18T16:00:00Z", "2026-06-19T00:00:00Z"),
        #("2026-06-19T16:00:00Z", "2026-06-19T23:00:00Z"),
      ]
    let assert [first, ..] = slots
    assert list.map(first.attendees, fn(attendee) {
        #(attendee.engineer_id, attendee.attendance)
      })
      == [
        #(3, meeting_command.Optional),
        #(2, meeting_command.Required),
      ]
  })
}

pub fn focus_block_splits_the_window_and_duration_filters_it_test() {
  rolling_back(fn(conn) {
    let assert Ok(split_by_focus_block) =
      meeting_view.find_time(
        ctx(conn),
        Date(2026, calendar.June, 22),
        Date(2026, calendar.June, 22),
        "America/Los_Angeles",
        120,
        [2],
        [],
        0,
      )
    assert spans(split_by_focus_block)
      == [
        #("2026-06-22T16:00:00Z", "2026-06-22T20:00:00Z"),
        #("2026-06-22T22:00:00Z", "2026-06-23T00:00:00Z"),
      ]

    let assert Ok(too_long_for_either_window) =
      meeting_view.find_time(
        ctx(conn),
        Date(2026, calendar.June, 22),
        Date(2026, calendar.June, 22),
        "America/Los_Angeles",
        300,
        [2],
        [],
        0,
      )
    assert too_long_for_either_window == []
  })
}

pub fn holiday_subtracts_the_day_for_the_holidays_own_region_test() {
  rolling_back(fn(conn) {
    let assert Ok(marcus_loses_the_california_holiday) =
      meeting_view.find_time(
        ctx(conn),
        Date(2026, calendar.September, 7),
        Date(2026, calendar.September, 11),
        "America/Los_Angeles",
        60,
        [2],
        [],
        0,
      )
    assert spans(marcus_loses_the_california_holiday)
      == [
        #("2026-09-07T16:00:00Z", "2026-09-08T00:00:00Z"),
        #("2026-09-08T16:00:00Z", "2026-09-09T00:00:00Z"),
        #("2026-09-10T16:00:00Z", "2026-09-11T00:00:00Z"),
        #("2026-09-11T16:00:00Z", "2026-09-12T00:00:00Z"),
      ]

    let assert Ok(priya_is_unaffected_by_the_california_holiday) =
      meeting_view.find_time(
        ctx(conn),
        Date(2026, calendar.September, 7),
        Date(2026, calendar.September, 11),
        "America/Los_Angeles",
        60,
        [1],
        [],
        0,
      )
    assert spans(priya_is_unaffected_by_the_california_holiday)
      == [
        #("2026-09-07T08:00:00Z", "2026-09-07T16:00:00Z"),
        #("2026-09-08T08:00:00Z", "2026-09-08T16:00:00Z"),
        #("2026-09-09T08:00:00Z", "2026-09-09T16:00:00Z"),
        #("2026-09-10T08:00:00Z", "2026-09-10T16:00:00Z"),
      ]
  })
}

pub fn an_unlocated_required_attendee_never_yields_a_slot_test() {
  rolling_back(fn(conn) {
    let engineer_id = insert_engineer(conn)
    insert_work_schedule(conn, engineer_id)
    let assert Ok(slots) =
      meeting_view.find_time(
        ctx(conn),
        Date(2026, calendar.June, 15),
        Date(2026, calendar.June, 19),
        "Europe/London",
        60,
        [engineer_id],
        [],
        0,
      )
    assert slots == []
  })
}

pub fn exclude_vacates_the_meetings_own_slot_test() {
  rolling_back(fn(conn) {
    let assert Ok(_) =
      command.dispatch_in(
        conn,
        "tester",
        gateway.MeetingCommand(meeting_command.ScheduleMeeting(
          title: "Full day sync",
          timezone: "America/Los_Angeles",
          date: Date(2026, calendar.June, 23),
          starts_at: "09:00",
          duration_minutes: 480,
          location: None,
          client_id: None,
          project_id: None,
          attendees: [#(2, Required)],
          check: meeting_command.AllowOverlap,
        )),
      )
    let meeting_id = meeting_id_by_title(conn, "Full day sync")

    let assert Ok(without_exclude) =
      meeting_view.find_time(
        ctx(conn),
        Date(2026, calendar.June, 23),
        Date(2026, calendar.June, 23),
        "America/Los_Angeles",
        480,
        [2],
        [],
        0,
      )
    assert without_exclude == []

    let assert Ok(with_exclude) =
      meeting_view.find_time(
        ctx(conn),
        Date(2026, calendar.June, 23),
        Date(2026, calendar.June, 23),
        "America/Los_Angeles",
        480,
        [2],
        [],
        meeting_id,
      )
    assert spans(with_exclude)
      == [#("2026-06-23T16:00:00Z", "2026-06-24T00:00:00Z")]
  })
}

pub fn a_duplicate_required_id_does_not_fail_the_coverage_guard_test() {
  rolling_back(fn(conn) {
    let assert Ok(deduped) =
      meeting_view.find_time(
        ctx(conn),
        Date(2026, calendar.June, 15),
        Date(2026, calendar.June, 19),
        "Europe/London",
        60,
        [2, 2],
        [],
        0,
      )
    let assert Ok(single) =
      meeting_view.find_time(
        ctx(conn),
        Date(2026, calendar.June, 15),
        Date(2026, calendar.June, 19),
        "Europe/London",
        60,
        [2],
        [],
        0,
      )
    assert spans(deduped) == spans(single)
    assert deduped != []
  })
}

pub fn project_team_for_project_300_returns_its_two_engineers_test() {
  rolling_back(fn(conn) {
    let assert Ok(team) =
      meeting_view.project_team(ctx(conn), 300, Date(2026, calendar.June, 15))
    assert team == [2, 3]
  })
}

pub fn a_scheduled_meeting_is_busy_and_a_cancelled_one_is_not_test() {
  rolling_back(fn(conn) {
    let assert Ok(_) =
      command.dispatch_in(
        conn,
        "tester",
        gateway.MeetingCommand(meeting_command.ScheduleMeeting(
          title: "Midday sync",
          timezone: "America/Los_Angeles",
          date: Date(2026, calendar.June, 23),
          starts_at: "12:00",
          duration_minutes: 60,
          location: None,
          client_id: None,
          project_id: None,
          attendees: [#(2, Required)],
          check: meeting_command.AllowOverlap,
        )),
      )
    let meeting_id = meeting_id_by_title(conn, "Midday sync")

    let assert Ok(split_by_the_meeting) =
      meeting_view.find_time(
        ctx(conn),
        Date(2026, calendar.June, 23),
        Date(2026, calendar.June, 23),
        "America/Los_Angeles",
        60,
        [2],
        [],
        0,
      )
    assert spans(split_by_the_meeting)
      == [
        #("2026-06-23T16:00:00Z", "2026-06-23T19:00:00Z"),
        #("2026-06-23T20:00:00Z", "2026-06-24T00:00:00Z"),
      ]

    let assert Ok(_) =
      command.dispatch_in(
        conn,
        "tester",
        gateway.MeetingCommand(meeting_command.CancelMeeting(meeting_id:)),
      )

    let assert Ok(whole_window_after_cancel) =
      meeting_view.find_time(
        ctx(conn),
        Date(2026, calendar.June, 23),
        Date(2026, calendar.June, 23),
        "America/Los_Angeles",
        60,
        [2],
        [],
        0,
      )
    assert spans(whole_window_after_cancel)
      == [#("2026-06-23T16:00:00Z", "2026-06-24T00:00:00Z")]
  })
}
