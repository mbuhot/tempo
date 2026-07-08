//// This module contains the code to run the sql queries defined in
//// `./src/tempo/server/meeting/sql`.
//// > 🐿️ This module was generated automatically using v4.7.0 of
//// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
////

import gleam/dynamic/decode
import gleam/option.{type Option}
import gleam/time/calendar.{type Date}
import pog

/// A row you get from running the `booking_conflicts` query
/// defined in `./src/tempo/server/meeting/sql/booking_conflicts.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type BookingConflictsRow {
  BookingConflictsRow(engineer_id: Int)
}

/// booking_conflicts.sql — inside the booking transaction, AFTER engineer_lock.sql
/// has taken its row lock: recompute each required attendee's availability against
/// now-committed state and report which ones no longer hold the window free. Same
/// algorithm as find_a_time.sql (free = work_schedule hours in the engineer's own
/// as-of TZID, minus busy = live bookings ∪ focus blocks ∪ leave days ∪ holidays)
/// but for ONE fixed window instead of a search span: $2/$3/$4/$5 pin the window
/// the same way meeting_booking_open.sql does, and the candidate-day span is the
/// window's own UTC dates ±2 (wide enough to cover any attendee's TZID offset).
/// Returns one row per required engineer whose available multirange does NOT
/// contain (`@>`) the window — the conflicted attendees the caller must fail the
/// operation for. An engineer with no location on the window's date has no free
/// hours at all, so it always comes back conflicted. Empty result = safe to book.
/// $1 required engineer ids (comma-separated text), $2 date, $3 starts_at (HH:MM),
/// $4 duration minutes, $5 timezone, $6 excluded meeting id (0 = none, e.g. the
/// meeting being rescheduled — vacates its own current booking).
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn booking_conflicts(
  db: pog.Connection,
  arg_1: String,
  arg_2: String,
  arg_3: String,
  arg_4: String,
  arg_5: String,
  arg_6: Int,
) -> Result(pog.Returned(BookingConflictsRow), pog.QueryError) {
  let decoder = {
    use engineer_id <- decode.field(0, decode.int)
    decode.success(BookingConflictsRow(engineer_id:))
  }

  "-- booking_conflicts.sql — inside the booking transaction, AFTER engineer_lock.sql
-- has taken its row lock: recompute each required attendee's availability against
-- now-committed state and report which ones no longer hold the window free. Same
-- algorithm as find_a_time.sql (free = work_schedule hours in the engineer's own
-- as-of TZID, minus busy = live bookings ∪ focus blocks ∪ leave days ∪ holidays)
-- but for ONE fixed window instead of a search span: $2/$3/$4/$5 pin the window
-- the same way meeting_booking_open.sql does, and the candidate-day span is the
-- window's own UTC dates ±2 (wide enough to cover any attendee's TZID offset).
-- Returns one row per required engineer whose available multirange does NOT
-- contain (`@>`) the window — the conflicted attendees the caller must fail the
-- operation for. An engineer with no location on the window's date has no free
-- hours at all, so it always comes back conflicted. Empty result = safe to book.
-- $1 required engineer ids (comma-separated text), $2 date, $3 starts_at (HH:MM),
-- $4 duration minutes, $5 timezone, $6 excluded meeting id (0 = none, e.g. the
-- meeting being rescheduled — vacates its own current booking).
WITH params AS (
  SELECT tstzrange(
           (($2::text || ' ' || $3::text)::timestamp AT TIME ZONE $5),
           (($2::text || ' ' || $3::text)::timestamp AT TIME ZONE $5) + ($4::text || ' minutes')::interval,
           '[)') AS occupies
),
attendee AS (
  SELECT trim(x)::bigint AS engineer_id
    FROM unnest(string_to_array($1, ',')) AS x
),
days AS (
  SELECT d::date AS day
    FROM generate_series(
           (lower((SELECT occupies FROM params)) AT TIME ZONE 'UTC')::date - 2,
           (upper((SELECT occupies FROM params)) AT TIME ZONE 'UTC')::date + 2,
           interval '1 day'
         ) AS d
),
located AS (
  SELECT a.engineer_id, d.day, loc.timezone AS tzid, loc.country, loc.region
    FROM attendee a
   CROSS JOIN days d
    JOIN engineer_location loc
      ON loc.engineer_id = a.engineer_id AND loc.located_during @> d.day
),
free_days AS (
  SELECT l.engineer_id,
         tstzrange(
           (l.day::text || ' ' || ws.starts::text)::timestamp AT TIME ZONE l.tzid,
           (l.day::text || ' ' || ws.ends::text)::timestamp AT TIME ZONE l.tzid,
           '[)') AS win
    FROM located l
    JOIN work_schedule ws
      ON ws.engineer_id = l.engineer_id
     AND ws.valid_at @> l.day
     AND ws.weekday = extract(isodow FROM l.day)::int - 1
),
free AS (
  SELECT a.engineer_id,
         coalesce(range_agg(f.win), '{}'::tstzmultirange) AS free
    FROM attendee a
    LEFT JOIN free_days f ON f.engineer_id = a.engineer_id
   GROUP BY a.engineer_id
),
busy_source AS MATERIALIZED (
  SELECT ma.engineer_id, b.occupies AS r
    FROM meeting_attendee ma
    JOIN attendee a ON a.engineer_id = ma.engineer_id
    JOIN meeting_booking b
      ON b.meeting_id = ma.meeting_id AND upper_inf(b.booked_during)
   WHERE b.occupies && (SELECT occupies FROM params)
     AND b.meeting_id IS DISTINCT FROM nullif($6, 0)
  UNION ALL
  SELECT f.engineer_id, f.busy_at
    FROM focus_block f
    JOIN attendee a ON a.engineer_id = f.engineer_id
   WHERE f.busy_at && (SELECT occupies FROM params)
  UNION ALL
  SELECT l.engineer_id,
         tstzrange((l.day::text || ' 00:00')::timestamp AT TIME ZONE l.tzid,
                   ((l.day + 1)::text || ' 00:00')::timestamp AT TIME ZONE l.tzid, '[)')
    FROM located l
    JOIN leave lv ON lv.engineer_id = l.engineer_id AND lv.on_leave_during @> l.day
  UNION ALL
  SELECT l.engineer_id,
         tstzrange((l.day::text || ' 00:00')::timestamp AT TIME ZONE l.tzid,
                   ((l.day + 1)::text || ' 00:00')::timestamp AT TIME ZONE l.tzid, '[)')
    FROM located l
    JOIN holiday h
      ON h.country = l.country AND h.region IN ('', l.region) AND h.holiday_on = l.day
),
busy AS (
  SELECT engineer_id, range_agg(r) AS busy FROM busy_source GROUP BY engineer_id
),
avail AS (
  SELECT f.engineer_id, f.free - coalesce(b.busy, '{}'::tstzmultirange) AS available
    FROM free f
    LEFT JOIN busy b USING (engineer_id)
)
SELECT a.engineer_id
  FROM avail a, params p
 WHERE NOT (a.available @> p.occupies)
 ORDER BY a.engineer_id;
"
  |> pog.query
  |> pog.parameter(pog.text(arg_1))
  |> pog.parameter(pog.text(arg_2))
  |> pog.parameter(pog.text(arg_3))
  |> pog.parameter(pog.text(arg_4))
  |> pog.parameter(pog.text(arg_5))
  |> pog.parameter(pog.int(arg_6))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `engineer_lock` query
/// defined in `./src/tempo/server/meeting/sql/engineer_lock.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type EngineerLockRow {
  EngineerLockRow(id: Int)
}

/// engineer_lock.sql — take a row lock on the required attendees' engineer rows
/// before re-checking availability inside the booking transaction: the finder's
/// suggestion was computed seconds-to-minutes earlier and may be stale by the time
/// a human books it, so the write path must serialize against any other write
/// racing the same attendee rather than trust a bare re-check under READ COMMITTED
/// (write-skew: two concurrent bookings could each see the OLD committed state and
/// both pass). Always acquired in ascending id order (ORDER BY id) so two bookings
/// sharing attendees never lock in opposite orders and deadlock. $1 = required
/// engineer ids (comma-separated text).
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn engineer_lock(
  db: pog.Connection,
  arg_1: String,
) -> Result(pog.Returned(EngineerLockRow), pog.QueryError) {
  let decoder = {
    use id <- decode.field(0, decode.int)
    decode.success(EngineerLockRow(id:))
  }

  "-- engineer_lock.sql — take a row lock on the required attendees' engineer rows
-- before re-checking availability inside the booking transaction: the finder's
-- suggestion was computed seconds-to-minutes earlier and may be stale by the time
-- a human books it, so the write path must serialize against any other write
-- racing the same attendee rather than trust a bare re-check under READ COMMITTED
-- (write-skew: two concurrent bookings could each see the OLD committed state and
-- both pass). Always acquired in ascending id order (ORDER BY id) so two bookings
-- sharing attendees never lock in opposite orders and deadlock. $1 = required
-- engineer ids (comma-separated text).
SELECT id FROM engineer WHERE id = ANY(string_to_array($1, ',')::bigint[]) ORDER BY id FOR UPDATE;
"
  |> pog.query
  |> pog.parameter(pog.text(arg_1))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `find_a_time` query
/// defined in `./src/tempo/server/meeting/sql/find_a_time.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type FindATimeRow {
  FindATimeRow(
    starts_at: String,
    ends_at: String,
    engineer_id: Int,
    name: Option(String),
    attendance: String,
    timezone: Option(String),
    offset_minutes: Option(Int),
    viewer_offset_minutes: Int,
  )
}

/// find_a_time.sql — cross-timezone slot finder: the search span (in the viewer's
/// timezone) x each candidate day's per-attendee work-schedule window, minus every
/// attendee's busy time (scheduled meetings, focus blocks, leave days, holidays),
/// intersected across every REQUIRED attendee (optional attendees ride along for
/// their offsets but never narrow the windows). Free/busy per engineer is built as a
/// `tstzmultirange` (a disjoint union of instant ranges) so subtraction and
/// intersection compose with simple multirange operators (`-`, `*`) instead of
/// hand-rolled interval arithmetic. `common` sums the required attendees' available
/// multiranges via `range_intersect_agg` and `guarded` only keeps the result when
/// every required attendee actually contributed a row (`covered = count(required)`)
/// — an attendee absent from `avail` (no location on any day, so `free` folded to
/// an empty multirange via the LEFT JOIN) must not silently drop out of the
/// requirement; instead the whole intersection is empty, i.e. zero slots. $1 from
/// date, $2 to date, $3 viewer timezone, $4 duration minutes, $5 required engineer
/// ids (comma-separated text), $6 optional engineer ids (comma-separated text, ''
/// = none), $7 excluded meeting id (0 = none, e.g. the meeting being rescheduled).
/// viewer_offset_minutes is $3's UTC offset (minutes east) at the slot start, the
/// same epoch-subtraction formula as the per-attendee offset below — the wizard
/// has no timezone library, so the server ships the offset it needs to convert a
/// chosen slot back into a viewer-local `date` + `starts_at` for the booking
/// command. Always resolvable ($3 is validated before this query runs), so unlike
/// the per-attendee offset it is NOT nullable.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn find_a_time(
  db: pog.Connection,
  arg_1: Date,
  arg_2: Date,
  arg_3: String,
  arg_4: Int,
  arg_5: String,
  arg_6: String,
  arg_7: Int,
) -> Result(pog.Returned(FindATimeRow), pog.QueryError) {
  let decoder = {
    use starts_at <- decode.field(0, decode.string)
    use ends_at <- decode.field(1, decode.string)
    use engineer_id <- decode.field(2, decode.int)
    use name <- decode.field(3, decode.optional(decode.string))
    use attendance <- decode.field(4, decode.string)
    use timezone <- decode.field(5, decode.optional(decode.string))
    use offset_minutes <- decode.field(6, decode.optional(decode.int))
    use viewer_offset_minutes <- decode.field(7, decode.int)
    decode.success(FindATimeRow(
      starts_at:,
      ends_at:,
      engineer_id:,
      name:,
      attendance:,
      timezone:,
      offset_minutes:,
      viewer_offset_minutes:,
    ))
  }

  "-- find_a_time.sql — cross-timezone slot finder: the search span (in the viewer's
-- timezone) x each candidate day's per-attendee work-schedule window, minus every
-- attendee's busy time (scheduled meetings, focus blocks, leave days, holidays),
-- intersected across every REQUIRED attendee (optional attendees ride along for
-- their offsets but never narrow the windows). Free/busy per engineer is built as a
-- `tstzmultirange` (a disjoint union of instant ranges) so subtraction and
-- intersection compose with simple multirange operators (`-`, `*`) instead of
-- hand-rolled interval arithmetic. `common` sums the required attendees' available
-- multiranges via `range_intersect_agg` and `guarded` only keeps the result when
-- every required attendee actually contributed a row (`covered = count(required)`)
-- — an attendee absent from `avail` (no location on any day, so `free` folded to
-- an empty multirange via the LEFT JOIN) must not silently drop out of the
-- requirement; instead the whole intersection is empty, i.e. zero slots. $1 from
-- date, $2 to date, $3 viewer timezone, $4 duration minutes, $5 required engineer
-- ids (comma-separated text), $6 optional engineer ids (comma-separated text, ''
-- = none), $7 excluded meeting id (0 = none, e.g. the meeting being rescheduled).
-- viewer_offset_minutes is $3's UTC offset (minutes east) at the slot start, the
-- same epoch-subtraction formula as the per-attendee offset below — the wizard
-- has no timezone library, so the server ships the offset it needs to convert a
-- chosen slot back into a viewer-local `date` + `starts_at` for the booking
-- command. Always resolvable ($3 is validated before this query runs), so unlike
-- the per-attendee offset it is NOT nullable.
WITH params AS (
  SELECT tstzrange(
           ($1::date::text || ' 00:00')::timestamp AT TIME ZONE $3,
           (($2::date + 1)::text || ' 00:00')::timestamp AT TIME ZONE $3,
           '[)') AS search,
         make_interval(mins => $4) AS dur
),
attendee AS (
  SELECT trim(x)::bigint AS engineer_id, 'required' AS attendance
    FROM unnest(string_to_array($5, ',')) AS x
  UNION ALL
  SELECT trim(x)::bigint, 'optional'
    FROM unnest(string_to_array(nullif($6, ''), ',')) AS x
),
days AS (
  SELECT d::date AS day
    FROM generate_series($1::date - 1, $2::date + 1, interval '1 day') AS d
),
located AS (
  SELECT a.engineer_id, a.attendance, d.day, loc.timezone AS tzid, loc.country, loc.region
    FROM attendee a
   CROSS JOIN days d
    JOIN engineer_location loc
      ON loc.engineer_id = a.engineer_id AND loc.located_during @> d.day
),
free_days AS (
  SELECT l.engineer_id,
         tstzrange(
           (l.day::text || ' ' || ws.starts::text)::timestamp AT TIME ZONE l.tzid,
           (l.day::text || ' ' || ws.ends::text)::timestamp AT TIME ZONE l.tzid,
           '[)') AS win
    FROM located l
    JOIN work_schedule ws
      ON ws.engineer_id = l.engineer_id
     AND ws.valid_at @> l.day
     AND ws.weekday = extract(isodow FROM l.day)::int - 1
),
free AS (
  SELECT a.engineer_id, a.attendance,
         coalesce(range_agg(f.win), '{}'::tstzmultirange) AS free
    FROM attendee a
    LEFT JOIN free_days f ON f.engineer_id = a.engineer_id
   GROUP BY a.engineer_id, a.attendance
),
busy_source AS MATERIALIZED (
  SELECT ma.engineer_id, b.occupies AS r
    FROM meeting_attendee ma
    JOIN attendee a ON a.engineer_id = ma.engineer_id
    JOIN meeting_booking b
      ON b.meeting_id = ma.meeting_id AND upper_inf(b.booked_during)
   WHERE b.occupies && (SELECT search FROM params)
     AND b.meeting_id IS DISTINCT FROM nullif($7, 0)
  UNION ALL
  SELECT f.engineer_id, f.busy_at
    FROM focus_block f
    JOIN attendee a ON a.engineer_id = f.engineer_id
   WHERE f.busy_at && (SELECT search FROM params)
  UNION ALL
  SELECT l.engineer_id,
         tstzrange((l.day::text || ' 00:00')::timestamp AT TIME ZONE l.tzid,
                   ((l.day + 1)::text || ' 00:00')::timestamp AT TIME ZONE l.tzid, '[)')
    FROM located l
    JOIN leave lv ON lv.engineer_id = l.engineer_id AND lv.on_leave_during @> l.day
  UNION ALL
  SELECT l.engineer_id,
         tstzrange((l.day::text || ' 00:00')::timestamp AT TIME ZONE l.tzid,
                   ((l.day + 1)::text || ' 00:00')::timestamp AT TIME ZONE l.tzid, '[)')
    FROM located l
    JOIN holiday h
      ON h.country = l.country AND h.region IN ('', l.region) AND h.holiday_on = l.day
),
busy AS (
  SELECT engineer_id, range_agg(r) AS busy FROM busy_source GROUP BY engineer_id
),
avail AS (
  SELECT f.engineer_id, f.attendance,
         f.free - coalesce(b.busy, '{}'::tstzmultirange) AS available
    FROM free f
    LEFT JOIN busy b USING (engineer_id)
),
common AS (
  SELECT range_intersect_agg(available) AS windows, count(*) AS covered
    FROM avail WHERE attendance = 'required'
),
guarded AS (
  SELECT windows * tstzmultirange((SELECT search FROM params)) AS windows
    FROM common
   WHERE covered = (SELECT count(*) FROM attendee WHERE attendance = 'required')
),
slot AS (
  SELECT w.win
    FROM guarded g, unnest(g.windows) AS w(win)
   WHERE upper(w.win) - lower(w.win) >= (SELECT dur FROM params)
   ORDER BY lower(w.win)
   LIMIT 50
)
SELECT to_char(lower(s.win) AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"') AS starts_at,
       to_char(upper(s.win) AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"') AS ends_at,
       a.engineer_id,
       ec.name AS name,
       a.attendance,
       loc.timezone AS \"timezone?\",
       CASE WHEN loc.timezone IS NULL THEN NULL
            ELSE ((extract(epoch from (lower(s.win) AT TIME ZONE loc.timezone))
                   - extract(epoch from (lower(s.win) AT TIME ZONE 'UTC'))) / 60)::int
       END AS \"offset_minutes?\",
       ((extract(epoch from (lower(s.win) AT TIME ZONE $3))
         - extract(epoch from (lower(s.win) AT TIME ZONE 'UTC'))) / 60)::int AS viewer_offset_minutes
FROM slot s
CROSS JOIN attendee a
JOIN engineer_current ec ON ec.id = a.engineer_id
LEFT JOIN engineer_location loc
       ON loc.engineer_id = a.engineer_id
      AND loc.located_during @> (lower(s.win) AT TIME ZONE 'UTC')::date
ORDER BY lower(s.win), a.attendance, ec.name;
"
  |> pog.query
  |> pog.parameter(pog.calendar_date(arg_1))
  |> pog.parameter(pog.calendar_date(arg_2))
  |> pog.parameter(pog.text(arg_3))
  |> pog.parameter(pog.int(arg_4))
  |> pog.parameter(pog.text(arg_5))
  |> pog.parameter(pog.text(arg_6))
  |> pog.parameter(pog.int(arg_7))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// meeting_attendee_delete.sql — drop an attendee. $1 meeting_id, $2 engineer_id.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn meeting_attendee_delete(
  db: pog.Connection,
  meeting_id: Int,
  arg_2: Int,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- meeting_attendee_delete.sql — drop an attendee. $1 meeting_id, $2 engineer_id.
DELETE FROM meeting_attendee WHERE meeting_id = $1 AND engineer_id = $2;
"
  |> pog.query
  |> pog.parameter(pog.int(meeting_id))
  |> pog.parameter(pog.int(arg_2))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// meeting_attendee_insert.sql — add or re-mark an attendee. $1 meeting_id, $2 engineer_id,
/// $3 attendance (required|optional).
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn meeting_attendee_insert(
  db: pog.Connection,
  arg_1: Int,
  arg_2: Int,
  arg_3: String,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- meeting_attendee_insert.sql — add or re-mark an attendee. $1 meeting_id, $2 engineer_id,
-- $3 attendance (required|optional).
INSERT INTO meeting_attendee (meeting_id, engineer_id, attendance)
VALUES ($1, $2, $3)
ON CONFLICT (meeting_id, engineer_id) DO UPDATE SET attendance = EXCLUDED.attendance;
"
  |> pog.query
  |> pog.parameter(pog.int(arg_1))
  |> pog.parameter(pog.int(arg_2))
  |> pog.parameter(pog.text(arg_3))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `meeting_attendees_asof` query
/// defined in `./src/tempo/server/meeting/sql/meeting_attendees_asof.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type MeetingAttendeesAsofRow {
  MeetingAttendeesAsofRow(
    meeting_id: Int,
    engineer_id: Int,
    name: Option(String),
    attendance: String,
    timezone: Option(String),
    local_offset_minutes: Option(Int),
  )
}

/// meeting_attendees_asof.sql — attendees of the currently-live meetings ending on/after
/// $1, each with name and their location-tz-as-of-$1 local UTC offset at the meeting
/// start. Unlocated attendees have NULL timezone/offset. "Live" is the open booking
/// (`upper_inf(booked_during)`). $1 = as_of date.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn meeting_attendees_asof(
  db: pog.Connection,
  arg_1: Date,
) -> Result(pog.Returned(MeetingAttendeesAsofRow), pog.QueryError) {
  let decoder = {
    use meeting_id <- decode.field(0, decode.int)
    use engineer_id <- decode.field(1, decode.int)
    use name <- decode.field(2, decode.optional(decode.string))
    use attendance <- decode.field(3, decode.string)
    use timezone <- decode.field(4, decode.optional(decode.string))
    use local_offset_minutes <- decode.field(5, decode.optional(decode.int))
    decode.success(MeetingAttendeesAsofRow(
      meeting_id:,
      engineer_id:,
      name:,
      attendance:,
      timezone:,
      local_offset_minutes:,
    ))
  }

  "-- meeting_attendees_asof.sql — attendees of the currently-live meetings ending on/after
-- $1, each with name and their location-tz-as-of-$1 local UTC offset at the meeting
-- start. Unlocated attendees have NULL timezone/offset. \"Live\" is the open booking
-- (`upper_inf(booked_during)`). $1 = as_of date.
SELECT a.meeting_id AS meeting_id,
       a.engineer_id AS engineer_id,
       ec.name AS name,
       a.attendance AS attendance,
       loc.timezone AS timezone,
       CASE WHEN loc.timezone IS NULL THEN NULL
            ELSE ((extract(epoch from (lower(b.occupies) AT TIME ZONE loc.timezone))
                   - extract(epoch from (lower(b.occupies) AT TIME ZONE 'UTC'))) / 60)::int
       END AS \"local_offset_minutes?\"
FROM meeting_attendee a
JOIN meeting_booking b ON b.meeting_id = a.meeting_id AND upper_inf(b.booked_during)
JOIN engineer_current ec ON ec.id = a.engineer_id
LEFT JOIN engineer_location loc
       ON loc.engineer_id = a.engineer_id AND loc.located_during @> $1::date
WHERE upper(b.occupies) >= $1::date
ORDER BY a.meeting_id, ec.name;
"
  |> pog.query
  |> pog.parameter(pog.calendar_date(arg_1))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `meeting_booking_close` query
/// defined in `./src/tempo/server/meeting/sql/meeting_booking_close.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type MeetingBookingCloseRow {
  MeetingBookingCloseRow(meeting_id: Int, location: Option(String))
}

/// meeting_booking_close.sql — close the meeting's currently open booking (a cancel, or
/// the first half of a reschedule) at $2, the real-clock instant of this write (text,
/// from meeting_clock_now.sql). No `@>` filter: closes whatever open tail exists.
/// RETURNING empty means no booking was open (already cancelled, or the meeting doesn't
/// exist) — the repository rejects that as NoSuchVersion. RETURNING `location` carries
/// the closed booking's location forward into a reschedule's successor row, since
/// RescheduleMeeting doesn't itself carry a location.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn meeting_booking_close(
  db: pog.Connection,
  meeting_id: Int,
  arg_2: String,
) -> Result(pog.Returned(MeetingBookingCloseRow), pog.QueryError) {
  let decoder = {
    use meeting_id <- decode.field(0, decode.int)
    use location <- decode.field(1, decode.optional(decode.string))
    decode.success(MeetingBookingCloseRow(meeting_id:, location:))
  }

  "-- meeting_booking_close.sql — close the meeting's currently open booking (a cancel, or
-- the first half of a reschedule) at $2, the real-clock instant of this write (text,
-- from meeting_clock_now.sql). No `@>` filter: closes whatever open tail exists.
-- RETURNING empty means no booking was open (already cancelled, or the meeting doesn't
-- exist) — the repository rejects that as NoSuchVersion. RETURNING `location` carries
-- the closed booking's location forward into a reschedule's successor row, since
-- RescheduleMeeting doesn't itself carry a location.
DELETE FROM meeting_booking
   FOR PORTION OF booked_during FROM ($2::text)::timestamptz TO NULL
 WHERE meeting_id = $1
RETURNING meeting_id, location;
"
  |> pog.query
  |> pog.parameter(pog.int(meeting_id))
  |> pog.parameter(pog.text(arg_2))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// meeting_booking_open.sql — open a new booking: the instant range the meeting occupies,
/// live from $7 onward. $1 meeting_id, $2 date, $3 starts_at (HH:MM), $4
/// duration_minutes, $5 timezone, $6 location ('' = null), $7 the real-clock instant this
/// booking becomes live (text, from meeting_clock_now.sql), $8 audit_id.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn meeting_booking_open(
  db: pog.Connection,
  arg_1: Int,
  arg_2: String,
  arg_3: String,
  arg_4: String,
  arg_5: String,
  arg_6: String,
  arg_7: String,
  arg_8: Int,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- meeting_booking_open.sql — open a new booking: the instant range the meeting occupies,
-- live from $7 onward. $1 meeting_id, $2 date, $3 starts_at (HH:MM), $4
-- duration_minutes, $5 timezone, $6 location ('' = null), $7 the real-clock instant this
-- booking becomes live (text, from meeting_clock_now.sql), $8 audit_id.
INSERT INTO meeting_booking (meeting_id, occupies, meeting_tz, location, booked_during, audit_id)
VALUES (
  $1,
  tstzrange(
    (($2::text || ' ' || $3::text)::timestamp AT TIME ZONE $5),
    (($2::text || ' ' || $3::text)::timestamp AT TIME ZONE $5) + ($4::text || ' minutes')::interval,
    '[)'),
  $5,
  nullif($6, ''),
  tstzrange(($7::text)::timestamptz, NULL, '[)'),
  $8);
"
  |> pog.query
  |> pog.parameter(pog.int(arg_1))
  |> pog.parameter(pog.text(arg_2))
  |> pog.parameter(pog.text(arg_3))
  |> pog.parameter(pog.text(arg_4))
  |> pog.parameter(pog.text(arg_5))
  |> pog.parameter(pog.text(arg_6))
  |> pog.parameter(pog.text(arg_7))
  |> pog.parameter(pog.int(arg_8))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `meeting_clock_now` query
/// defined in `./src/tempo/server/meeting/sql/meeting_clock_now.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type MeetingClockNowRow {
  MeetingClockNowRow(at: String)
}

/// meeting_clock_now.sql — the real wall-clock instant for a booking transition,
/// rendered to text at the boundary. `clock_timestamp()`, not `now()`: `now()` is frozen
/// at transaction start, so a close-then-open within one transaction would stamp both
/// halves with the identical instant.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn meeting_clock_now(
  db: pog.Connection,
) -> Result(pog.Returned(MeetingClockNowRow), pog.QueryError) {
  let decoder = {
    use at <- decode.field(0, decode.string)
    decode.success(MeetingClockNowRow(at:))
  }

  "-- meeting_clock_now.sql — the real wall-clock instant for a booking transition,
-- rendered to text at the boundary. `clock_timestamp()`, not `now()`: `now()` is frozen
-- at transaction start, so a close-then-open within one transaction would stamp both
-- halves with the identical instant.
SELECT clock_timestamp()::text AS at;
"
  |> pog.query
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `meeting_create` query
/// defined in `./src/tempo/server/meeting/sql/meeting_create.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type MeetingCreateRow {
  MeetingCreateRow(id: Int)
}

/// meeting_create.sql — mint a new meeting identity row, returning its id.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn meeting_create(
  db: pog.Connection,
) -> Result(pog.Returned(MeetingCreateRow), pog.QueryError) {
  let decoder = {
    use id <- decode.field(0, decode.int)
    decode.success(MeetingCreateRow(id:))
  }

  "-- meeting_create.sql — mint a new meeting identity row, returning its id.
INSERT INTO meeting DEFAULT VALUES RETURNING id;
"
  |> pog.query
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `meeting_required_attendees` query
/// defined in `./src/tempo/server/meeting/sql/meeting_required_attendees.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type MeetingRequiredAttendeesRow {
  MeetingRequiredAttendeesRow(engineer_id: Int)
}

/// meeting_required_attendees.sql — the required attendees on $1's roster, for the
/// RequireFree reschedule guard to lock and re-check (only required attendees gate
/// a booking; optional attendees never block it). $1 = meeting_id.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn meeting_required_attendees(
  db: pog.Connection,
  meeting_id: Int,
) -> Result(pog.Returned(MeetingRequiredAttendeesRow), pog.QueryError) {
  let decoder = {
    use engineer_id <- decode.field(0, decode.int)
    decode.success(MeetingRequiredAttendeesRow(engineer_id:))
  }

  "-- meeting_required_attendees.sql — the required attendees on $1's roster, for the
-- RequireFree reschedule guard to lock and re-check (only required attendees gate
-- a booking; optional attendees never block it). $1 = meeting_id.
SELECT engineer_id FROM meeting_attendee WHERE meeting_id = $1 AND attendance = 'required' ORDER BY engineer_id;
"
  |> pog.query
  |> pog.parameter(pog.int(meeting_id))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// meeting_subject_insert.sql — insert a meeting's subject (title, client, project).
/// $1 meeting_id, $2 title, $3 client_id (0 = null), $4 project_id (0 = null), $5 audit_id.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn meeting_subject_insert(
  db: pog.Connection,
  arg_1: Int,
  arg_2: String,
  arg_3: Int,
  arg_4: Int,
  arg_5: Int,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- meeting_subject_insert.sql — insert a meeting's subject (title, client, project).
-- $1 meeting_id, $2 title, $3 client_id (0 = null), $4 project_id (0 = null), $5 audit_id.
INSERT INTO meeting_subject (meeting_id, title, client_id, project_id, audit_id)
VALUES ($1, $2, nullif($3, 0), nullif($4, 0), $5);
"
  |> pog.query
  |> pog.parameter(pog.int(arg_1))
  |> pog.parameter(pog.text(arg_2))
  |> pog.parameter(pog.int(arg_3))
  |> pog.parameter(pog.int(arg_4))
  |> pog.parameter(pog.int(arg_5))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `meetings_upcoming` query
/// defined in `./src/tempo/server/meeting/sql/meetings_upcoming.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type MeetingsUpcomingRow {
  MeetingsUpcomingRow(
    meeting_id: Int,
    title: String,
    meeting_tz: String,
    starts_at: String,
    ends_at: String,
    canonical_offset_minutes: Int,
    location: Option(String),
    client_id: Option(Int),
    project_id: Option(Int),
  )
}

/// meetings_upcoming.sql — currently-live meetings ending on/after $1, earliest first.
/// "Live" is derived, not stored: `upper_inf(b.booked_during)` is the open booking, i.e.
/// scheduled. Times cross the wire as ISO-8601 UTC strings; canonical_offset_minutes is
/// meeting_tz's UTC offset (minutes east) at the meeting start. $1 = as_of date.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn meetings_upcoming(
  db: pog.Connection,
  arg_1: Date,
) -> Result(pog.Returned(MeetingsUpcomingRow), pog.QueryError) {
  let decoder = {
    use meeting_id <- decode.field(0, decode.int)
    use title <- decode.field(1, decode.string)
    use meeting_tz <- decode.field(2, decode.string)
    use starts_at <- decode.field(3, decode.string)
    use ends_at <- decode.field(4, decode.string)
    use canonical_offset_minutes <- decode.field(5, decode.int)
    use location <- decode.field(6, decode.optional(decode.string))
    use client_id <- decode.field(7, decode.optional(decode.int))
    use project_id <- decode.field(8, decode.optional(decode.int))
    decode.success(MeetingsUpcomingRow(
      meeting_id:,
      title:,
      meeting_tz:,
      starts_at:,
      ends_at:,
      canonical_offset_minutes:,
      location:,
      client_id:,
      project_id:,
    ))
  }

  "-- meetings_upcoming.sql — currently-live meetings ending on/after $1, earliest first.
-- \"Live\" is derived, not stored: `upper_inf(b.booked_during)` is the open booking, i.e.
-- scheduled. Times cross the wire as ISO-8601 UTC strings; canonical_offset_minutes is
-- meeting_tz's UTC offset (minutes east) at the meeting start. $1 = as_of date.
SELECT m.id AS meeting_id,
       s.title AS title,
       b.meeting_tz AS meeting_tz,
       to_char(lower(b.occupies) AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"') AS starts_at,
       to_char(upper(b.occupies) AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"') AS ends_at,
       ((extract(epoch from (lower(b.occupies) AT TIME ZONE b.meeting_tz))
         - extract(epoch from (lower(b.occupies) AT TIME ZONE 'UTC'))) / 60)::int AS canonical_offset_minutes,
       b.location AS location,
       s.client_id AS client_id,
       s.project_id AS project_id
FROM meeting_booking b
JOIN meeting m ON m.id = b.meeting_id
JOIN meeting_subject s ON s.meeting_id = b.meeting_id
WHERE upper_inf(b.booked_during)
  AND upper(b.occupies) >= $1::date
ORDER BY lower(b.occupies), m.id;
"
  |> pog.query
  |> pog.parameter(pog.calendar_date(arg_1))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `project_team_asof` query
/// defined in `./src/tempo/server/meeting/sql/project_team_asof.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type ProjectTeamAsofRow {
  ProjectTeamAsofRow(engineer_id: Int)
}

/// project_team_asof.sql — the distinct engineers allocated to project $1 as-of
/// date $2 (the "Fill from project" affordance in the find-a-time wizard, per the
/// design doc's participant table). $1 = project_id, $2 = as-of date.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn project_team_asof(
  db: pog.Connection,
  project_id: Int,
  arg_2: Date,
) -> Result(pog.Returned(ProjectTeamAsofRow), pog.QueryError) {
  let decoder = {
    use engineer_id <- decode.field(0, decode.int)
    decode.success(ProjectTeamAsofRow(engineer_id:))
  }

  "-- project_team_asof.sql — the distinct engineers allocated to project $1 as-of
-- date $2 (the \"Fill from project\" affordance in the find-a-time wizard, per the
-- design doc's participant table). $1 = project_id, $2 = as-of date.
SELECT DISTINCT engineer_id
FROM allocation
WHERE project_id = $1 AND allocated_during @> $2::date
ORDER BY engineer_id;
"
  |> pog.query
  |> pog.parameter(pog.int(project_id))
  |> pog.parameter(pog.calendar_date(arg_2))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `timezone_valid` query
/// defined in `./src/tempo/server/meeting/sql/timezone_valid.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type TimezoneValidRow {
  TimezoneValidRow(valid: Bool)
}

/// timezone_valid.sql — whether $1 is a TZID PostgreSQL recognises. $1 = timezone.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn timezone_valid(
  db: pog.Connection,
  arg_1: String,
) -> Result(pog.Returned(TimezoneValidRow), pog.QueryError) {
  let decoder = {
    use valid <- decode.field(0, decode.bool)
    decode.success(TimezoneValidRow(valid:))
  }

  "-- timezone_valid.sql — whether $1 is a TZID PostgreSQL recognises. $1 = timezone.
SELECT EXISTS (SELECT 1 FROM pg_timezone_names WHERE name = $1) AS valid;
"
  |> pog.query
  |> pog.parameter(pog.text(arg_1))
  |> pog.returning(decoder)
  |> pog.execute(db)
}
