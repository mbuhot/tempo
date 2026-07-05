//// This module contains the code to run the sql queries defined in
//// `./src/tempo/server/meeting/sql`.
//// > 🐿️ This module was generated automatically using v4.7.0 of
//// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
////

import gleam/dynamic/decode
import gleam/option.{type Option}
import gleam/time/calendar.{type Date}
import pog

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
    local_offset_minutes: Int,
  )
}

/// meeting_attendees_asof.sql — attendees of the scheduled meetings ending on/after $1,
/// each with name and their location-tz-as-of-$1 local UTC offset at the meeting start.
/// Unlocated attendees have NULL timezone/offset. $1 = as_of date.
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
    use local_offset_minutes <- decode.field(5, decode.int)
    decode.success(MeetingAttendeesAsofRow(
      meeting_id:,
      engineer_id:,
      name:,
      attendance:,
      timezone:,
      local_offset_minutes:,
    ))
  }

  "-- meeting_attendees_asof.sql — attendees of the scheduled meetings ending on/after $1,
-- each with name and their location-tz-as-of-$1 local UTC offset at the meeting start.
-- Unlocated attendees have NULL timezone/offset. $1 = as_of date.
SELECT a.meeting_id AS meeting_id,
       a.engineer_id AS engineer_id,
       ec.name AS name,
       a.attendance AS attendance,
       loc.timezone AS timezone,
       CASE WHEN loc.timezone IS NULL THEN NULL
            ELSE ((extract(epoch from (lower(d.meeting_at) AT TIME ZONE loc.timezone))
                   - extract(epoch from (lower(d.meeting_at) AT TIME ZONE 'UTC'))) / 60)::int
       END AS local_offset_minutes
FROM meeting_attendee a
JOIN meeting_detail d ON d.meeting_id = a.meeting_id AND d.status = 'scheduled'
JOIN engineer_current ec ON ec.id = a.engineer_id
LEFT JOIN engineer_location loc
       ON loc.engineer_id = a.engineer_id AND loc.located_during @> $1::date
WHERE upper(d.meeting_at) >= $1::date
ORDER BY a.meeting_id, ec.name;
"
  |> pog.query
  |> pog.parameter(pog.calendar_date(arg_1))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `meeting_cancel` query
/// defined in `./src/tempo/server/meeting/sql/meeting_cancel.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type MeetingCancelRow {
  MeetingCancelRow(meeting_id: Int)
}

/// meeting_cancel.sql — mark a meeting cancelled. $1 meeting_id, $2 audit_id.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn meeting_cancel(
  db: pog.Connection,
  meeting_id: Int,
  audit_id: Int,
) -> Result(pog.Returned(MeetingCancelRow), pog.QueryError) {
  let decoder = {
    use meeting_id <- decode.field(0, decode.int)
    decode.success(MeetingCancelRow(meeting_id:))
  }

  "-- meeting_cancel.sql — mark a meeting cancelled. $1 meeting_id, $2 audit_id.
UPDATE meeting_detail SET status = 'cancelled', audit_id = $2
WHERE meeting_id = $1
RETURNING meeting_id;
"
  |> pog.query
  |> pog.parameter(pog.int(meeting_id))
  |> pog.parameter(pog.int(audit_id))
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

/// meeting_detail_insert.sql — insert a meeting's detail. $1 meeting_id, $2 date,
/// $3 starts_at (HH:MM), $4 duration_minutes, $5 timezone, $6 title, $7 location ('' = null),
/// $8 client_id (0 = null), $9 project_id (0 = null), $10 audit_id.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn meeting_detail_insert(
  db: pog.Connection,
  arg_1: Int,
  arg_2: String,
  arg_3: String,
  arg_4: String,
  arg_5: String,
  arg_6: String,
  arg_7: String,
  arg_8: Int,
  arg_9: Int,
  arg_10: Int,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- meeting_detail_insert.sql — insert a meeting's detail. $1 meeting_id, $2 date,
-- $3 starts_at (HH:MM), $4 duration_minutes, $5 timezone, $6 title, $7 location ('' = null),
-- $8 client_id (0 = null), $9 project_id (0 = null), $10 audit_id.
INSERT INTO meeting_detail
  (meeting_id, meeting_at, meeting_tz, title, location, status, client_id, project_id, audit_id)
VALUES (
  $1,
  tstzrange(
    (($2::text || ' ' || $3::text)::timestamp AT TIME ZONE $5),
    (($2::text || ' ' || $3::text)::timestamp AT TIME ZONE $5) + ($4::text || ' minutes')::interval,
    '[)'),
  $5, $6, nullif($7, ''), 'scheduled', nullif($8, 0), nullif($9, 0), $10);
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
  |> pog.parameter(pog.int(arg_9))
  |> pog.parameter(pog.int(arg_10))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `meeting_reschedule` query
/// defined in `./src/tempo/server/meeting/sql/meeting_reschedule.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type MeetingRescheduleRow {
  MeetingRescheduleRow(meeting_id: Int)
}

/// meeting_reschedule.sql — move a meeting in place. $1 meeting_id, $2 date, $3 starts_at,
/// $4 duration_minutes, $5 timezone, $6 audit_id. RETURNING gates a missing meeting.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn meeting_reschedule(
  db: pog.Connection,
  meeting_id: Int,
  arg_2: String,
  arg_3: String,
  arg_4: String,
  arg_5: String,
  audit_id: Int,
) -> Result(pog.Returned(MeetingRescheduleRow), pog.QueryError) {
  let decoder = {
    use meeting_id <- decode.field(0, decode.int)
    decode.success(MeetingRescheduleRow(meeting_id:))
  }

  "-- meeting_reschedule.sql — move a meeting in place. $1 meeting_id, $2 date, $3 starts_at,
-- $4 duration_minutes, $5 timezone, $6 audit_id. RETURNING gates a missing meeting.
UPDATE meeting_detail SET
  meeting_at = tstzrange(
    (($2::text || ' ' || $3::text)::timestamp AT TIME ZONE $5),
    (($2::text || ' ' || $3::text)::timestamp AT TIME ZONE $5) + ($4::text || ' minutes')::interval,
    '[)'),
  meeting_tz = $5,
  audit_id   = $6
WHERE meeting_id = $1
RETURNING meeting_id;
"
  |> pog.query
  |> pog.parameter(pog.int(meeting_id))
  |> pog.parameter(pog.text(arg_2))
  |> pog.parameter(pog.text(arg_3))
  |> pog.parameter(pog.text(arg_4))
  |> pog.parameter(pog.text(arg_5))
  |> pog.parameter(pog.int(audit_id))
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

/// meetings_upcoming.sql — scheduled meetings ending on/after $1, earliest first. Times
/// cross the wire as ISO-8601 UTC strings; canonical_offset_minutes is meeting_tz's UTC
/// offset (minutes east) at the meeting start. $1 = as_of date.
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

  "-- meetings_upcoming.sql — scheduled meetings ending on/after $1, earliest first. Times
-- cross the wire as ISO-8601 UTC strings; canonical_offset_minutes is meeting_tz's UTC
-- offset (minutes east) at the meeting start. $1 = as_of date.
SELECT m.id AS meeting_id,
       d.title AS title,
       d.meeting_tz AS meeting_tz,
       to_char(lower(d.meeting_at) AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"') AS starts_at,
       to_char(upper(d.meeting_at) AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"') AS ends_at,
       ((extract(epoch from (lower(d.meeting_at) AT TIME ZONE d.meeting_tz))
         - extract(epoch from (lower(d.meeting_at) AT TIME ZONE 'UTC'))) / 60)::int AS canonical_offset_minutes,
       d.location AS location,
       d.client_id AS client_id,
       d.project_id AS project_id
FROM meeting_detail d
JOIN meeting m ON m.id = d.meeting_id
WHERE d.status = 'scheduled'
  AND upper(d.meeting_at) >= $1::date
ORDER BY lower(d.meeting_at), m.id;
"
  |> pog.query
  |> pog.parameter(pog.calendar_date(arg_1))
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
