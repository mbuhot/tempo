# Scheduling Phase B — Availability inputs: design

Issue #43, part of the #42 scheduling roadmap. Umbrella design: `docs/2026-07-04-scheduling-calendar-design.md` (Layer B).

Phase B records everything the Phase D finder intersects and subtracts: per-weekday working hours, personal focus blocks, and regional public holidays. Working hours are **local wall-clock** times pinned to instants through the engineer's as-of TZID; day-granular facts (holidays, leave) expand to instants in the engineer's own timezone.

## Decisions

| # | Decision |
|---|----------|
| B1 | Phase B ships editing UI for all three inputs: a People-detail **Availability panel** (weekly hours + focus blocks) and a **Holidays section** on the Locations page. |
| B2 | `holiday_region.region` / `holiday.region` are `text NOT NULL DEFAULT ''`; `''` means nationwide. PK columns must be NOT NULL and FKs need a unique target, so the sentinel keeps `PRIMARY KEY (country, region)` and every FK enforced. |
| B3 | Every engineer gets a seeded default 9:00–17:00 Mon–Fri schedule. Availability semantics live entirely in the data; the finder stays a pure intersection. A missing weekday row means no working hours that day. |
| B4 | Holidays arrive by seed (AU/US/GB 2026 demo dataset) plus an `ImportHolidays` batch command through the dispatch/audit seam. Annual refresh = paste the year's dataset. Regions are seeded reference data; an import row naming an unknown `(country, region)` fails with `InvalidValue`. |
| B5 | Schedule and focus-block writes use `Owned` policy — `availability.manage.any` (manager/owner) or `availability.manage.own` acting on one's own record — mirroring `TakeLeave`. Holiday import is `Direct` on a new `holiday.manage` (owner). |
| B6 | The work-schedule write is a whole-week batch: `SetWorkSchedule(engineer_id, effective, 7-day grid)` — one command, one journal entry, atomic "my hours from date D". The UI is a bespoke weekly-grid editor (the scalar op-form cannot hold a 7×3 grid); focus-block add/remove are flat and reuse the op-form engine. |
| B7 | `work_schedule` is a temporal fact (`valid_at daterange`, `WITHOUT OVERLAPS`, set-from-date via `FOR PORTION OF`) exactly like `engineer_location`. `focus_block` rows are plain and mutable (the Phase C meeting pattern): add = INSERT, remove = DELETE, `audit_id` carries who/when. |
| B8 | Phase A carry-forward: the migration normalizes `engineer_location.region` NULL→`''`, makes it NOT NULL, backfills `holiday_region`, and adds the FK `engineer_location (country, region) → holiday_region`, so a location naming an unknown region fails on write. |

## Schema (one migration)

```sql
CREATE TABLE holiday_region (
  country text NOT NULL,                -- ISO-3166-1 alpha-2
  region  text NOT NULL DEFAULT '',     -- ISO-3166-2 subdivision; '' = nationwide
  name    text NOT NULL,
  PRIMARY KEY (country, region)
);

CREATE TABLE holiday (
  country    text   NOT NULL,
  region     text   NOT NULL DEFAULT '',
  holiday_on date   NOT NULL,
  name       text   NOT NULL,
  audit_id   bigint NOT NULL REFERENCES event_log (id),
  PRIMARY KEY (country, region, holiday_on),
  FOREIGN KEY (country, region) REFERENCES holiday_region (country, region)
);
CREATE INDEX holiday_audit_id_idx ON holiday (audit_id);

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
CREATE INDEX work_schedule_audit_id_idx ON work_schedule (audit_id);

CREATE TABLE focus_block (
  id          bigint    GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  engineer_id bigint    NOT NULL REFERENCES engineer (id),
  busy_at     tstzrange NOT NULL,
  title       text      NOT NULL,
  audit_id    bigint    NOT NULL REFERENCES event_log (id)
);
CREATE INDEX focus_block_audit_id_idx ON focus_block (audit_id);
CREATE INDEX focus_block_busy_gist ON focus_block USING gist (engineer_id, busy_at);

UPDATE engineer_location SET region = '' WHERE region IS NULL;
ALTER TABLE engineer_location ALTER COLUMN region SET NOT NULL,
                              ALTER COLUMN region SET DEFAULT '';
INSERT INTO holiday_region (country, region, name) VALUES
  ('AU', '', 'Australia'), ('AU', 'AU-NSW', 'New South Wales'),
  ('US', '', 'United States'), ('US', 'US-CA', 'California'),
  ('GB', '', 'United Kingdom'), ('GB', 'GB-LND', 'London');
ALTER TABLE engineer_location
  ADD FOREIGN KEY (country, region) REFERENCES holiday_region (country, region);
```

The GiST index on `focus_block` is the per-source busy index the finder validates in Phase D.

The FK add requires every `(country, region)` already present in `engineer_location` (across base, demo, and e2e seeds) to exist in `holiday_region`; the implementation plan verifies the distinct set and extends the backfill list if a seed has grown beyond the six rows above.

## Commands

New concept `availability` (`shared/availability/command.gleam`, `server/.../availability/{command,view,http}.gleam` + `sql/`), plus `holiday` import routed through the same concept module (one concept, both tables — they ship and change together).

| Command | Fields | Semantics |
|---|---|---|
| `SetWorkSchedule` | `engineer_id: Int`, `effective: Date`, `days: List(#(Int, Option(#(String, String))))` — exactly 7 entries, weekdays 0–6 each once, times `"HH:MM"` | Per weekday: `DELETE FOR PORTION OF valid_at FROM effective TO NULL`, then INSERT `[effective, ∞)` when `Some(starts, ends)`. Malformed grid (≠7 entries, duplicate weekday, `starts >= ends`, unparseable time) → `InvalidValue`. |
| `AddFocusBlock` | `engineer_id, date, starts_at "HH:MM", duration_minutes, timezone, title` | TZID validated against `pg_timezone_names`; `busy_at` composed with the Phase C `tstzrange` expression. |
| `RemoveFocusBlock` | `focus_block_id: Int` | DELETE by id; empty RETURNING → `NoSuchVersion`. |
| `ImportHolidays` | `rows: List(#(String, String, Date, String))` — country, region (`''` = nationwide), date, name | Pre-check every `(country, region)` exists in `holiday_region`, else `InvalidValue` naming the offender; then upsert `ON CONFLICT (country, region, holiday_on) DO UPDATE SET name`. |

**Facts** stay row-level (one `repository.write` per row): `SetWorkSchedule` → 7× `WorkHoursSet(engineer_id, weekday, effective, starts, ends)` / `WorkDayCleared(engineer_id, weekday, effective)`; `AddFocusBlock` → `FocusBlockAdded(…)`; `RemoveFocusBlock` → `FocusBlockRemoved(id)`; `ImportHolidays` → N× `HolidayImported(country, region, date, name)`.

**Policy:** `ManageAvailability -> Owned(access.availability_manage_own, access.availability_manage_any)` for the first three; `ManageHolidays -> Direct(access.holiday_manage)` for import. Permission strings `availability.manage.own` / `availability.manage.any` / `holiday.manage`. Grants: `.any` → manager, owner; `.own` → every engineer-holding role (mirror `leave.take.own`'s grant rows); `holiday.manage` → owner.

## Reads

| Endpoint | Returns | Gate |
|---|---|---|
| `GET /api/engineers/:id/availability?as_of=` | `{ week: [7 × {weekday, starts?, ends?}] (as-of grid), focus_blocks: [{id, title, starts_at ISO-UTC, ends_at ISO-UTC, offset_minutes}] (ending on/after as_of, offset = engineer's as-of TZID at block start), holidays: [{holiday_on, name}] (next 10 for the engineer's as-of (country, region), nationwide + subdivision) }` | `read_engineers` |
| `GET /api/holidays?as_of=` | `[{country, region, region_name, holiday_on, name}]` — holidays on/after `as_of`, date order | `read_engineers` |

## UI

- **People detail → Availability panel** (beside the Phase A location panel): the as-of weekly grid rendered read-only; Edit (permit `own`/`any`) opens the bespoke weekly editor — 7 rows of working-toggle + start/end time inputs, one effective-from date, one Save building `SetWorkSchedule`. Focus blocks listed with local times; Add and Remove are flat op-form modals (`OpAddFocusBlock`, `OpRemoveFocusBlock`). Upcoming-holidays strip from the availability read.
- **Locations page → Holidays section:** upcoming holidays grouped by region (`region_name`); Import (permit `holiday.manage`) opens a paste modal — one `country,region,date,name` CSV line per holiday, parsed client-side with a row-count preview, submitting `ImportHolidays`.

## Seed

Base and e2e seeds both:
- Default 9:00–17:00 Mon–Fri (`valid_at [2024-01-01, ∞)`) for every seeded engineer.
- Priya (engineer 1) drops Friday from 2026-07-01 — a part-time scenario straddling seed-now 2026-06-15 and her London relocation.
- One Marcus focus block after seed-now.
- A deterministic handful of 2026 holidays per seeded region (AU/AU-NSW, US/US-CA, GB/GB-LND) with exact dates pinned in the implementation plan.
- `rbac_seed.sql`: the three new permissions and their grants.

## Testing

| Layer | Coverage |
|---|---|
| Dispatch (server) | week-set inserts 7 rows; re-set from a later date splits via FOR PORTION and the as-of read sees both eras; cleared day disappears; malformed grid → `InvalidValue`; focus add/remove round-trip; remove missing id → `NoSuchVersion`; import upserts and re-import updates the name; unknown region → `InvalidValue`; own-permission accepted on self, rejected on others (mirror the leave auth tests). |
| Reads (server) | availability fold (grid + blocks + regional holidays, nationwide and subdivision both matching); holidays listing ordered and named. |
| Client units | weekly-grid form → `SetWorkSchedule` builder (valid, day-off, bad time); focus op-form builders; import paste parser (valid lines, bad line rejected with message). |
| e2e | edit own hours → grid shows the new hours; add a focus block → appears with local time; holidays section lists a seeded holiday; an engineer without `.any` sees Edit only on their own panel. |

## Out of scope

Phase D consumes these inputs: the finder, free/busy computation, and meeting-time suggestions. Leave already exists and is unchanged. Holiday auto-refresh from an external API stays a manual annual import.
