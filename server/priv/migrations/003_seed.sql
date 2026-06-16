-- 003_seed.sql — the single source-of-truth v1-wide seed (P2-T03).
--
-- Deterministic and hand-written: explicit ids, names, dates, and rates — no
-- factory sequences (ARCHITECTURE.md §10 "Determinism", PRD §9). This same seed
-- is consumed unchanged by the P3 as-of query tests, the P4 Playwright suite,
-- and the P5 migration oracle, so it must stay stable.
--
-- Fixed seed "now" = 2026-06-15. The UI slider and every test anchor to this
-- date instead of the system clock. It is documented here (the single source)
-- and re-stated wherever code needs it.
--
-- Every demo beat (PRD §7) has the data it needs:
--   * future-dated promotion ...... Marcus Chen: L4 -> L5 at 2026-07-01 (after now)
--   * leave overlapping allocation . Aisha Okafor: annual 2026-06-08..2026-06-22
--                                    (covers now and her live project-300 allocation)
--   * rate-card change ............. L5 day_rate 1200 -> 1400 at 2026-07-01
--   * fractional split ............. Priya Sharma: 0.5 on project 100 AND 0.5 on 200
--   * cached-rate fragmentation .... allocation rows split at every rate/level
--                                    boundary, adjacent rows differing only by
--                                    day_rate, so v2 range_agg has something to merge
--
-- Seed invariant (ARCHITECTURE.md §7): for every allocation row, day_rate equals
-- rate_card[engineer_role.level] for the overlapping period. Asserted at the end
-- of this file; the migration aborts if it is ever violated.
--
-- Ids are explicit. Identity tables (engineer, client) are GENERATED ALWAYS AS
-- IDENTITY, so OVERRIDING SYSTEM VALUE is used to pin their ids; the sequences
-- are then advanced past the seeded ids so later app inserts do not collide.

-- Identity -------------------------------------------------------------------
INSERT INTO client (id, name) OVERRIDING SYSTEM VALUE VALUES
  (1, 'Northwind Trading'),
  (2, 'Globex Corporation');

INSERT INTO engineer (id, name) OVERRIDING SYSTEM VALUE VALUES
  (1, 'Priya Sharma'),
  (2, 'Marcus Chen'),
  (3, 'Aisha Okafor');

-- Keep the IDENTITY sequences ahead of the pinned ids so future app-driven
-- inserts (which do NOT override) get fresh, non-colliding ids.
SELECT setval(pg_get_serial_sequence('client',   'id'), 2, true);
SELECT setval(pg_get_serial_sequence('engineer', 'id'), 3, true);

-- Rate card ------------------------------------------------------------------
-- One row per level per period. L5 steps up mid-2026 (the rate-card change
-- beat); it is also the FOR PORTION OF demo home for H2-2026 (PRD FR-6).
INSERT INTO rate_card (level, day_rate, valid_at) VALUES
  (3,  800.00, daterange('2024-01-01', '2027-01-01')),
  (4, 1000.00, daterange('2024-01-01', '2027-01-01')),
  (5, 1200.00, daterange('2024-01-01', '2026-07-01')),  -- L5 before the bump
  (5, 1400.00, daterange('2026-07-01', '2027-01-01')),  -- L5 after the bump
  (6, 1800.00, daterange('2024-01-01', '2027-01-01'));

-- Contracts & projects -------------------------------------------------------
INSERT INTO contract (id, client_id, valid_at) VALUES
  (10, 1, daterange('2024-01-01', '2027-01-01')),  -- Northwind
  (20, 2, daterange('2025-01-01', '2027-01-01'));   -- Globex

INSERT INTO project (id, contract_id, name, valid_at) VALUES
  (100, 10, 'Ledger Migration', daterange('2024-01-01', '2027-01-01')),
  (200, 10, 'Inventory Sync',   daterange('2025-06-01', '2027-01-01')),
  (300, 20, 'Data Platform',    daterange('2025-01-01', '2027-01-01'));

-- Employment -----------------------------------------------------------------
-- Root of the PERIOD-FK containment chain; every role/allocation/leave below
-- stays within these spans.
INSERT INTO employment (engineer_id, valid_at) VALUES
  (1, daterange('2024-01-01', '2027-01-01')),  -- Priya
  (2, daterange('2024-06-01', '2027-01-01')),  -- Marcus
  (3, daterange('2025-01-01', '2027-01-01'));   -- Aisha

-- Roles (levels) -------------------------------------------------------------
-- Marcus's L4 -> L5 row at 2026-07-01 is the future-dated promotion (after the
-- 2026-06-15 seed "now"); his level AND charge rate step up unaided when the
-- slider crosses it (PRD FR-3).
INSERT INTO engineer_role (engineer_id, level, valid_at) VALUES
  (1, 5, daterange('2024-01-01', '2027-01-01')),  -- Priya: L5 throughout
  (2, 4, daterange('2024-06-01', '2026-07-01')),  -- Marcus: L4 before promotion
  (2, 5, daterange('2026-07-01', '2027-01-01')),  -- Marcus: L5 after promotion
  (3, 6, daterange('2025-01-01', '2027-01-01'));   -- Aisha: L6 throughout

-- Allocations (v1-wide: day_rate cached) -------------------------------------
-- Each row's day_rate equals rate_card[role.level] for its period (the seed
-- invariant). Rows are deliberately FRAGMENTED at every rate/level boundary so
-- adjacent rows share project+fraction and differ only by the cached day_rate:
-- exactly what the v2-split range_agg coalescing later merges (ARCHITECTURE §7).
--
-- Priya — the fractional split: 0.5 on project 100 and 0.5 on project 200.
-- L5 rate bumps at 2026-07-01, so each engagement fragments there (1200 -> 1400).
INSERT INTO allocation (engineer_id, project_id, fraction, day_rate, valid_at) VALUES
  (1, 100, 0.50, 1200.00, daterange('2024-01-01', '2026-07-01')),
  (1, 100, 0.50, 1400.00, daterange('2026-07-01', '2027-01-01')),
  (1, 200, 0.50, 1200.00, daterange('2025-06-01', '2026-07-01')),
  (1, 200, 0.50, 1400.00, daterange('2026-07-01', '2027-01-01')),
-- Marcus — full-time on project 300. Both his promotion (L4->L5) and the L5 rate
-- bump fall on 2026-07-01, so the engagement fragments once there (1000 -> 1400).
  (2, 300, 1.00, 1000.00, daterange('2025-01-01', '2026-07-01')),
  (2, 300, 1.00, 1400.00, daterange('2026-07-01', '2027-01-01')),
-- Aisha — full-time on project 300 at L6; L6 rate is constant, so no
-- fragmentation: a single whole-engagement row.
  (3, 300, 1.00, 1800.00, daterange('2025-01-01', '2027-01-01'));

-- Leave ----------------------------------------------------------------------
-- Aisha is on annual leave across the seed "now" (2026-06-15). It overlaps her
-- live project-300 allocation, which the board suppresses in favour of
-- "On leave" (PRD FR-4).
INSERT INTO leave (engineer_id, kind, valid_at) VALUES
  (3, 'annual', daterange('2026-06-08', '2026-06-22'));

-- Timesheet ------------------------------------------------------------------
-- Priya logged hours on Tuesday 2026-06-09 against both her half-time projects.
-- The day is covered by both allocations (PERIOD-FK satisfied) and she is not on
-- leave, so the timesheet form/read tests have real data to assert on.
INSERT INTO timesheet (engineer_id, project_id, work_day, hours) VALUES
  (1, 100, daterange('2026-06-09', '2026-06-10'), 4.00),
  (1, 200, daterange('2026-06-09', '2026-06-10'), 4.00);

-- Seed invariant assertion ---------------------------------------------------
-- Fails the migration (rolls back the whole file) if any allocation row's cached
-- day_rate disagrees with the rate card for that engineer's level over the
-- overlapping period. This is the redundant-cache guarantee the v2-split slider
-- oracle relies on: v1 day_rate == v2's engineer_role × rate_card for every date.
DO $seed_invariant$
DECLARE
  mismatch_count int;
BEGIN
  SELECT count(*) INTO mismatch_count
  FROM allocation
  JOIN engineer_role
    ON engineer_role.engineer_id = allocation.engineer_id
   AND engineer_role.valid_at && allocation.valid_at
  JOIN rate_card
    ON rate_card.level = engineer_role.level
   AND rate_card.valid_at && (allocation.valid_at * engineer_role.valid_at)
  WHERE rate_card.day_rate <> allocation.day_rate
    -- only count periods that actually overlap all three facts
    AND NOT isempty(allocation.valid_at * engineer_role.valid_at * rate_card.valid_at);

  IF mismatch_count <> 0 THEN
    RAISE EXCEPTION
      'Seed invariant violated: % allocation period(s) have a cached day_rate '
      'that disagrees with rate_card[level] for the overlapping period',
      mismatch_count;
  END IF;
END
$seed_invariant$;
