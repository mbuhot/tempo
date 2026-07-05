-- 20260706090000_meeting_booking.sql — replace the plain mutable `meeting_detail` row
-- with two tables: `meeting_subject` (the mutable title/client/project correction) and
-- `meeting_booking`, a Change-pattern temporal fact over REAL time. A booking carries two
-- ranges: `occupies` is the wall-clock instant span the meeting takes place (the old
-- `meeting_at`); `booked_during` is the real-clock window during which that `occupies`
-- value stood as the live plan — it opens when the booking is created and closes when
-- superseded (reschedule) or cancelled. Status is derived, never stored: scheduled = a
-- booking row with `upper_inf(booked_during)`; cancelled = every booking row for the
-- meeting is closed with no successor; rescheduled = a closed row with a successor.
--
-- Backfill, best-effort (the old schema mutated in place, so there is no per-reschedule
-- row history to replay — only one booking per meeting can be reconstructed):
--   - `meeting_subject` copies straight across from `meeting_detail`.
--   - `meeting_booking`'s `booked_during` lower bound is the latest of: the
--     `schedule_meeting` event whose `payload->>'title'` matches the meeting's title
--     (schedule payloads carry no `meeting_id`, only title, since the id is minted
--     after), and any `reschedule_meeting` event whose `payload->>'meeting_id'` matches
--     this meeting (reschedule payloads do carry `meeting_id`) — `greatest()` of the two,
--     coalescing a missing reschedule match to `-infinity`.
--   - its upper bound is NULL unless the meeting is `cancelled`, in which case it is the
--     `occurred_at` of the event named by the row's own `audit_id` (the cancel SQL sets
--     `audit_id` to the cancelling event, so a cancelled row's `audit_id` IS that event).
--   - `occupies`/`meeting_tz`/`location`/`audit_id` carry across unchanged from
--     `meeting_detail`.

CREATE TABLE meeting_subject (
  meeting_id  bigint PRIMARY KEY REFERENCES meeting (id),
  title       text NOT NULL,
  client_id   bigint REFERENCES client (id),
  project_id  bigint REFERENCES project (id),
  audit_id    bigint NOT NULL REFERENCES event_log (id)
);
CREATE INDEX meeting_subject_audit_id_idx ON meeting_subject (audit_id);

CREATE TABLE meeting_booking (
  meeting_id     bigint NOT NULL REFERENCES meeting (id),
  occupies       tstzrange NOT NULL,
  meeting_tz     text NOT NULL,
  location       text,
  booked_during  tstzrange NOT NULL,
  audit_id       bigint NOT NULL REFERENCES event_log (id),
  CONSTRAINT meeting_booking_no_overlap
    PRIMARY KEY (meeting_id, booked_during WITHOUT OVERLAPS) DEFERRABLE INITIALLY IMMEDIATE
);
CREATE INDEX meeting_booking_audit_id_idx ON meeting_booking (audit_id);

INSERT INTO meeting_subject (meeting_id, title, client_id, project_id, audit_id)
SELECT meeting_id, title, client_id, project_id, audit_id FROM meeting_detail;

WITH opens AS (
  SELECT
    d.meeting_id,
    greatest(
      (SELECT e.occurred_at FROM event_log e
        WHERE e.operation = 'schedule_meeting' AND e.payload ->> 'title' = d.title
        ORDER BY e.occurred_at DESC LIMIT 1),
      coalesce(
        (SELECT max(e.occurred_at) FROM event_log e
          WHERE e.operation = 'reschedule_meeting'
            AND (e.payload ->> 'meeting_id')::bigint = d.meeting_id),
        '-infinity'::timestamptz)
    ) AS opened_at
  FROM meeting_detail d
),
closes AS (
  SELECT
    d.meeting_id,
    CASE WHEN d.status = 'cancelled'
      THEN (SELECT e.occurred_at FROM event_log e WHERE e.id = d.audit_id)
      ELSE NULL
    END AS closed_at
  FROM meeting_detail d
)
INSERT INTO meeting_booking (meeting_id, occupies, meeting_tz, location, booked_during, audit_id)
SELECT d.meeting_id, d.meeting_at, d.meeting_tz, d.location,
       tstzrange(opens.opened_at, closes.closed_at, '[)'),
       d.audit_id
FROM meeting_detail d
JOIN opens  ON opens.meeting_id = d.meeting_id
JOIN closes ON closes.meeting_id = d.meeting_id;

DROP TABLE meeting_detail;
