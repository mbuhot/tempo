# Scheduling & Calendar System — Design

**Date:** 2026-07-04
**Status:** Proposed
**Depends on:** PostgreSQL 18 temporal PKs (`WITHOUT OVERLAPS`), PG14 multiranges, PG19 `range_intersect_agg`

## Summary

A scheduling subsystem for a distributed workforce: track meetings with clients and
internal all-hands, and find fair meeting times across engineers whose location — and
therefore timezone — changes over time.

The load-bearing idea is tempo-native: **an engineer's timezone is an as-of query.**
Working hours are stored as local wall-clock; the instant they map to on any given day
depends on the location fact in force that day. Relocate someone on a date and every
future meeting's math shifts on its own date.

| Layer | New tables | Delivers |
|---|---|---|
| **A. Location** | `engineer_location` | the temporal timezone primitive; surfaced on the engineer screen |
| **B. Availability inputs** | `work_schedule`, `focus_block`, `holiday`, `holiday_region` | everything the finder intersects and subtracts |
| **C. Meetings** | `meeting`, `meeting_detail`, `meeting_attendee` | the calendar — create/edit/cancel, as-of-anchored view |
| **D. Finder** | *(query only)* | the cross-timezone "find a fair time" wizard + reschedule |

**Build order: A → C → (B+D).** Each phase is independently demoable. A comes first
because C's calendar renders each attendee's local time, which needs the timezone
primitive. B and D ship together because the finder needs all its inputs at once.

The subsystem follows tempo's house style: identity tables plus dated fact tables, typed
SQL via Squirrel, `shared` types and codecs, Lustre views, organized under a `scheduling/`
domain with per-concept `command.gleam` / `view.gleam`. All timezone and interval
arithmetic lives in PostgreSQL; Gleam and JavaScript never compute timezones.

## Timezone semantics (the core)

An engineer's **location** is a dated fact carrying an IANA **TZID** (`Australia/Sydney`).
Working hours are stored as **local wall-clock** `time` values. To place a working day on
the instant timeline, both are resolved **as-of that day** and combined:

```
(day + starts) AT TIME ZONE tzid   -- the engineer's TZID in force on `day`
```

Storing wall-clock hours keeps "9am standup" at 9am local across daylight-saving
transitions. PostgreSQL resolves the two DST edge cases deterministically: a
spring-forward nonexistent local time shifts forward; a fall-back ambiguous local time
takes the standard-time occurrence. Working hours of 09:00–17:00 never touch those
02:00–03:00 edges in practice.

Because every window is an **instant range**, engineers in different timezones intersect
correctly with no special casing: Sydney's Wednesday morning and San Francisco's Tuesday
afternoon are the same instants, and the algebra finds them.

**Day-granular facts (leave, holiday) expand to instants in the engineer's own TZID:**
a holiday on day D blocks `[D AT TIME ZONE tzid, (D+1) AT TIME ZONE tzid)`, so a Sydney
engineer's public holiday blocks their Sydney day, not a UTC day.

## Layer A — Location

```sql
CREATE TABLE engineer_location (
  engineer_id  bigint    NOT NULL REFERENCES engineer (id),
  located_during daterange NOT NULL,
  country      text      NOT NULL REFERENCES holiday_region (country),  -- ISO-3166-1 alpha-2
  region       text,                                                    -- ISO-3166-2 subdivision, nullable
  timezone     text      NOT NULL,                                      -- IANA TZID
  audit_id     bigint    NOT NULL REFERENCES event_log (id),
  PRIMARY KEY (engineer_id, located_during WITHOUT OVERLAPS)
);
```

- TZID validated against `pg_timezone_names` on write.
- As-of lookup: `located_during @> DATE 'D'`.
- Editing location "from date D" uses `FOR PORTION OF located_during` to clip and preserve
  the untouched remainder, the same UPDATE pattern the rest of tempo uses for dated facts.

## Layer B — Availability inputs

```sql
CREATE TABLE work_schedule (
  engineer_id bigint    NOT NULL REFERENCES engineer (id),
  weekday     int       NOT NULL CHECK (weekday BETWEEN 0 AND 6),  -- 0 = Monday
  valid_at    daterange NOT NULL,
  starts      time      NOT NULL,
  ends        time      NOT NULL,
  audit_id    bigint    NOT NULL REFERENCES event_log (id),
  CHECK (starts < ends),
  PRIMARY KEY (engineer_id, weekday, valid_at WITHOUT OVERLAPS)
);

CREATE TABLE focus_block (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  engineer_id bigint    NOT NULL REFERENCES engineer (id),
  busy_at     tstzrange NOT NULL,
  title       text      NOT NULL,
  audit_id    bigint    NOT NULL REFERENCES event_log (id)
);

CREATE TABLE holiday_region (
  country text NOT NULL,          -- ISO-3166-1 alpha-2
  region  text,                   -- ISO-3166-2 subdivision, nullable = nationwide
  name    text NOT NULL,
  PRIMARY KEY (country, region)
);

CREATE TABLE holiday (
  country    text NOT NULL,
  region     text,               -- nullable = applies nationwide
  holiday_on date NOT NULL,
  name       text NOT NULL,
  audit_id   bigint NOT NULL REFERENCES event_log (id),
  PRIMARY KEY (country, region, holiday_on),
  FOREIGN KEY (country, region) REFERENCES holiday_region (country, region)
);
```

- **Weekday dimension** lets `work_schedule` express part-time and non-working days
  (a missing weekday row = no working hours that day, so the finder never books it).
- **Holiday matching** joins on the engineer's as-of `(country, region)`: a nationwide
  row (`region IS NULL`) applies to everyone in the country; a subdivision row narrows to
  that region. Structured ISO codes keep the join exact.
- **Holiday sourcing** is a named operational task: per-country data is loaded from a
  public holiday dataset and refreshed annually. The reference table makes an unknown
  country a load-time foreign-key failure.

## Layer C — Meetings

A meeting's only meaningful data is its time and its attendees. It carries no fact history
of its own, so its rows are plain and mutable; `event_log` records who changed what and
when, as it does for every write in tempo.

```sql
CREATE TABLE meeting (id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY);

CREATE TABLE meeting_detail (
  meeting_id bigint    NOT NULL REFERENCES meeting (id),
  meeting_at tstzrange NOT NULL,
  title      text      NOT NULL,
  location   text,                          -- free-text video link / address; no availability constraint
  status     text      NOT NULL DEFAULT 'scheduled',   -- scheduled | cancelled
  client_id  bigint    REFERENCES client (id),
  project_id bigint    REFERENCES project (id),
  audit_id   bigint    NOT NULL REFERENCES event_log (id),
  PRIMARY KEY (meeting_id)
);

CREATE TABLE meeting_attendee (
  meeting_id bigint NOT NULL REFERENCES meeting (id) ON DELETE CASCADE,
  engineer_id bigint NOT NULL REFERENCES engineer (id),
  attendance text   NOT NULL DEFAULT 'required',       -- required | optional
  PRIMARY KEY (meeting_id, engineer_id)
);
```

- **Reschedule** = `UPDATE meeting_detail SET meeting_at = …` in place.
- **Cancel** = `UPDATE … SET status = 'cancelled'`; the finder's busy pool ignores
  cancelled meetings.
- **Required vs optional** attendance gates the finder (below): only required attendees
  constrain a suggestion.

## Layer D — The finder

The classic availability query, restructured so it holds across widely separated
timezones. Every attendee's windows and busy time are computed as **instant ranges**, then
combined with multirange algebra over the whole search period at once.

Per attendee, over the search period:

1. **Free hours** — for each day, resolve the as-of TZID (`engineer_location`), the day's
   `work_schedule` row for that weekday, and pin `[day+starts, day+ends)` to instants.
   `range_agg` the days into one `tstzmultirange`.
2. **Busy** — union, as instant ranges: meetings they attend where `status = 'scheduled'`;
   their `focus_block`s; leave days expanded in their TZID; holidays for their as-of
   `(country, region)` expanded in their TZID. `COALESCE(range_agg(…), '{}')`.
3. **Available** = free hours − busy (multirange subtraction).

Across attendees:

4. **Intersect** every *required* attendee's available multirange with
   `range_intersect_agg`; optional attendees do not constrain the result.
5. **Coverage guard** — `count(DISTINCT required attendee) = n`; an attendee with no
   windows drops out of the aggregate and must fail this check rather than silently
   shrinking the requirement.
6. `unnest` the intersection, keep windows ≥ the requested duration, clip to the search
   range.

**Participant modes** resolve to a required-attendee id array:

| Mode | Resolution |
|---|---|
| All Staff | every employed engineer as-of the date |
| Project Team | engineers allocated to the chosen project as-of the date (internal only) |
| Selected Staff | an explicit pick |

**Reschedule** reuses the query with `IS DISTINCT FROM $excluded_meeting` so the meeting
being moved vacates its own slot.

### Booking concurrency

Overlaps are allowed at the database: real calendars carry them (an all-hands over one
person's leave, an optional attendee already booked, a giveable focus block). No exclusion
constraint is imposed. Two guarantees instead:

- The finder never **suggests** a slot where a required attendee is busy.
- Booking a suggested slot **locks the required attendees, then re-runs their availability
  check inside the booking transaction**; if someone became busy since the suggestion, it
  returns "slot taken" and re-suggests. Manual booking may save any overlap with a UI warning.

A bare re-check is not enough: under `READ COMMITTED`, two concurrent bookings each re-check,
neither sees the other's uncommitted insert, and both commit — a write-skew. The lock closes
it. Acquire it **before** the re-check, over exactly the required attendees, in id order:

```sql
SELECT id FROM engineer
WHERE id = ANY($required_attendee_ids)
ORDER BY id
FOR UPDATE;
-- then re-check availability, INSERT meeting + attendees, COMMIT
```

`engineer` is a bare identity table that nothing else updates, so it serves as a purpose-built
lock target; `ORDER BY id` gives every booking the same acquisition order, so two bookings
sharing attendees cannot deadlock; the lock is transaction-scoped and released on commit. A
concurrent booking sharing any required attendee blocks until the first commits, then re-checks
against committed state. This serializes booking-vs-booking for a shared required attendee — the
actual double-book race — and deliberately does not lock against a concurrent leave or holiday
grant, since overlapping those is allowed.

### Search bounds and the day grid

The search range is a `tstzrange` pinned in the **viewer's** timezone. The per-attendee day
grid runs ±1 day around it so a far-timezone attendee's boundary day is included; the final
free multirange is clipped back to the exact search range.

## Frontend

| Surface | Phase | Shows |
|---|---|---|
| Engineer screen | A | current location + TZID, editable with an effective date (writes a dated fact); history under the as-of slider |
| Calendar | C | upcoming meetings anchored to the as-of date; each meeting in the viewer's timezone plus each attendee's local time; create / edit / cancel |
| Find-a-time wizard | D | mode → date range → duration → ranked free windows, each rendered in every attendee's local time so fairness is visible; one click books the meeting with those attendees |

## Guards and edges

| Guard | Purpose |
|---|---|
| `count(DISTINCT required) = n` | every required attendee produced availability |
| `COALESCE(range_agg(…), '{}')` | an empty calendar means fully free, never NULL-swallowed |
| `IS DISTINCT FROM $excluded` | reschedule vacates its own slot; NULL means exclude nothing |
| `AT TIME ZONE tzid` per day | pins each day with the attendee's as-of zone |
| TZID validated vs `pg_timezone_names` | rejects a bad zone on write |
| ISO `(country, region)` FK | a holiday for an unknown region fails at load |
| Missing location on a day | that engineer is surfaced as "no location set", excluded from that day rather than silently dropped |

**Performance** is re-measured for this schema rather than copied from any prior benchmark:
busy is a union of four sources (attended meetings, focus blocks, leave, holidays), so
indexing is validated per source (a GiST index on `focus_block (engineer_id, busy_at)`, the
attendee join via its primary key), busy is clipped to the search period, and busy CTEs are
`MATERIALIZED` to pin them to one execution.

## Testing

- **Finder (seed-driven, deterministic):** engineers across ≥3 timezones; assert exact free
  **instants**, including a Sydney↔San-Francisco slot that no shared calendar day contains, a
  window straddling a DST transition, and an engineer who **relocates mid-search-range** (the
  post-relocation days must pin to the new zone). Same-timezone assertions pass while these
  bugs bite, so the cross-timezone and relocation cases are the real coverage.
- **e2e (Playwright):** set an engineer's location; create a meeting and read attendee-local
  times; run the finder for a project team; book a suggested slot; cancel a meeting and
  confirm it leaves the busy pool.
- **Gleam unit:** as-of TZID lookup, participant-mode resolution, required/optional gating,
  codec round-trips.

## Alternatives considered

- **Per-day `GROUP BY` intersection (the classic single-room shape).** Rejected: once each
  attendee's window is pinned in their own zone, same-grid-day windows stop overlapping for
  wide timezone spreads, so the inverted-window guard drops every day and the finder reports
  no slots while real slots exist. Whole-period multiranges + `range_intersect_agg` replace it.
- **Bitemporal / superseded meetings.** Rejected: a meeting carries no fact history worth
  querying; a plain mutable row with `event_log` for who/when suffices.
- **`EXCLUDE USING gist` to prevent per-engineer overlap.** Rejected: with no RSVP/decline it
  would forbid every legitimate overlap forever, and it cannot cover leave/holiday/focus busy
  sources anyway. A `SELECT … FOR UPDATE` lock on the required attendees plus an in-transaction
  re-check covers the real concern.
- **`pg_advisory_xact_lock` per attendee, or `SERIALIZABLE` isolation, for the booking race.**
  Both work; advisory locks add a side-channel namespace to maintain, and `SERIALIZABLE` forces
  a 40001 retry loop on the whole booking path. Row-locking the identity rows closes the same
  race locally with no retry.
- **Timezone as a stored UTC offset.** Rejected: an offset breaks across DST; an IANA TZID
  resolves the correct offset per day.
- **Free-text country on the holiday join.** Rejected: `"Australia"` vs `"AU"` joins to
  nothing and silently drops holidays. ISO codes with a reference-table FK make a mismatch a
  load-time error.
