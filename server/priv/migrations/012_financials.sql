-- 012_financials.sql — the financial fact + identity tables (PRD-financials.md §3, §4).
--
-- Additive over the v2-split schema (the migration runner applies these in NNN
-- order; the oracle does NOT run 012, so its v1→v2 board replay is unaffected).
-- Same discipline as the core model (ARCHITECTURE.md §4): periods are
-- semantically named for the predicate they assert (ADR-018); WITHOUT OVERLAPS
-- primary keys and CHECK constraints carry explicit names so a violation
-- classifies to a typed OperationError (ADR-022).
--
-- The tables, by role:
--   * salary          — the COST analogue of rate_card: what we PAY a level over
--                        time. WITHOUT OVERLAPS (level) + FOR PORTION OF target,
--                        exactly like rate_card (what we CHARGE).
--   * invoice         — identity + immutable subject (which project, which month).
--   * invoice_status  — the temporal draft→issued→paid lifecycle (WITHOUT OVERLAPS).
--   * invoice_line    — the lines snapshotted when an invoice is drafted (plain rows).
--   * payroll_run     — a run for a month.
--   * payroll_line    — the prorated payment instruction per engineer.
--
-- No cross-entity PERIOD FKs (PRD-financials.md §3, §8): an invoice references a
-- project ENTITY id which — like contract — has no single-row identity table to
-- key against, so containment lives in the computing queries, not the schema. The
-- integrity that CAN be enforced (status non-overlap, the salary WITHOUT OVERLAPS,
-- value/status CHECKs) is.

-- "we pay level L this monthly salary" — the cost analogue of rate_card.
-- WITHOUT OVERLAPS per level (one salary per level per instant); revised via
-- FOR PORTION OF, exactly like rate_card.
CREATE TABLE salary (
  level          int NOT NULL CHECK (level BETWEEN 1 AND 7),
  monthly_salary numeric(10,2) NOT NULL,
  effective_during daterange NOT NULL,
  CONSTRAINT salary_no_overlap
    PRIMARY KEY (level, effective_during WITHOUT OVERLAPS)
);

-- "an invoice exists" — identity + immutable subject: which project, which month
-- (billing_period is the daterange covering that month). project_id is the
-- project ENTITY id (no identity table; see header).
CREATE TABLE invoice (
  id             int GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  project_id     int NOT NULL,
  billing_period daterange NOT NULL
);

-- "invoice N is in status S" — the temporal lifecycle. A transition caps the
-- current status and asserts the next (the Change pattern); WITHOUT OVERLAPS per
-- invoice rejects two statuses covering the same instant. Current status = the
-- row covering "now"; the full history stays queryable.
CREATE TABLE invoice_status (
  invoice_id int NOT NULL REFERENCES invoice(id),
  status     text NOT NULL CHECK (status IN ('draft', 'issued', 'paid')),
  status_during daterange NOT NULL,
  CONSTRAINT invoice_status_no_overlap
    PRIMARY KEY (invoice_id, status_during WITHOUT OVERLAPS)
);

-- The lines computed when an invoice is drafted: one per engineer who worked the
-- project in the period, at the contract-agreed day_rate. Plain rows — an issued
-- invoice's lines do not change (snapshotted at draft; PRD-financials.md §8).
CREATE TABLE invoice_line (
  invoice_id  int NOT NULL REFERENCES invoice(id),
  engineer_id int NOT NULL,
  level       int NOT NULL,
  day_rate    numeric(10,2) NOT NULL,
  days        numeric(8,2) NOT NULL,
  amount      numeric(12,2) NOT NULL
);

-- "a payroll run for a month" (period = the month's daterange).
CREATE TABLE payroll_run (
  id     int GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  period daterange NOT NULL
);

-- The payment instruction per engineer for a run: the prorated salary owed for
-- the period (proration split by engineer_role; PRD-financials.md FR-F5/F6).
CREATE TABLE payroll_line (
  run_id      int NOT NULL REFERENCES payroll_run(id),
  engineer_id int NOT NULL,
  amount      numeric(12,2) NOT NULL,
  days        numeric(8,2) NOT NULL
);

-- Baseline salaries -----------------------------------------------------------
-- Seed the cost rates for the levels the core seed uses (L3..L6), so payroll and
-- the P&L have data. Each monthly_salary is below the charge rate so the margin
-- is positive (rate_card day-rates: L3 800, L4 1000, L5 1200/1400, L6 1800).
-- Open-ended from 2024-01-01, matching the rate-card baseline span.
INSERT INTO salary (level, monthly_salary, effective_during) VALUES
  (3,  6000.00, daterange('2024-01-01', NULL, '[)')),
  (4,  8000.00, daterange('2024-01-01', NULL, '[)')),
  (5, 10000.00, daterange('2024-01-01', NULL, '[)')),
  (6, 14000.00, daterange('2024-01-01', NULL, '[)'));
