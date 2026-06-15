-- 002_facts.sql — the eight fact tables (v1-wide schema; ARCHITECTURE.md §4, §7).
--
-- Each fact is a narrow relation valid over a `daterange valid_at` (ADR-004).
-- WITHOUT OVERLAPS primary keys enforce "at most one row per key per instant";
-- PERIOD foreign keys enforce the temporal containment chain (PRD FR-5):
--
--   leave        ─┐
--                 ├─▶ employment
--   allocation  ──┘        └─▶ project ─▶ contract
--   engineer_role ─▶ employment
--   timesheet     ─▶ allocation
--
-- This is the v1-wide ("before") generation: `allocation` carries the
-- denormalized `day_rate` cache that v2-split later removes via range_agg
-- coalescing (ARCHITECTURE.md §7).

-- "engineer is employed" — the root of the containment chain.
CREATE TABLE employment (
  engineer_id int NOT NULL REFERENCES engineer(id),
  valid_at    daterange NOT NULL,
  PRIMARY KEY (engineer_id, valid_at WITHOUT OVERLAPS)
);

-- "engineer is at level L"; a promotion is a new row, not an UPDATE (ADR-009).
CREATE TABLE engineer_role (
  engineer_id int NOT NULL,
  level       int NOT NULL CHECK (level BETWEEN 1 AND 7),
  valid_at    daterange NOT NULL,
  PRIMARY KEY (engineer_id, valid_at WITHOUT OVERLAPS),
  FOREIGN KEY (engineer_id, PERIOD valid_at) REFERENCES employment (engineer_id, PERIOD valid_at)
);

-- L1–L7 charge rates, versioned over time; the FOR PORTION OF target (ADR-009).
CREATE TABLE rate_card (
  level    int NOT NULL CHECK (level BETWEEN 1 AND 7),
  day_rate numeric(10,2) NOT NULL,
  valid_at daterange NOT NULL,
  PRIMARY KEY (level, valid_at WITHOUT OVERLAPS)
);

-- "client engagement", a term.
CREATE TABLE contract (
  id        int NOT NULL,
  client_id int NOT NULL REFERENCES client(id),
  valid_at  daterange NOT NULL,
  PRIMARY KEY (id, valid_at WITHOUT OVERLAPS)
);

-- "project runs under a contract" (project ⊂ contract).
CREATE TABLE project (
  id          int NOT NULL,
  contract_id int NOT NULL,
  name        text NOT NULL,
  valid_at    daterange NOT NULL,
  PRIMARY KEY (id, valid_at WITHOUT OVERLAPS),
  FOREIGN KEY (contract_id, PERIOD valid_at) REFERENCES contract (id, PERIOD valid_at)
);

-- "engineer on project" (fractional; ⊂ employment AND ⊂ project).
-- v1-wide: `day_rate` caches the engineer's charge rate for the period so
-- billing need not join engineer_role × rate_card. Removed in v2-split.
CREATE TABLE allocation (
  engineer_id int NOT NULL,
  project_id  int NOT NULL,
  fraction    numeric(3,2) NOT NULL CHECK (fraction > 0 AND fraction <= 1),
  day_rate    numeric(10,2) NOT NULL,
  valid_at    daterange NOT NULL,
  PRIMARY KEY (engineer_id, project_id, valid_at WITHOUT OVERLAPS),
  FOREIGN KEY (engineer_id, PERIOD valid_at) REFERENCES employment (engineer_id, PERIOD valid_at),
  FOREIGN KEY (project_id,  PERIOD valid_at) REFERENCES project    (id,          PERIOD valid_at)
);

-- "engineer on leave" (⊂ employment; overrides allocation in the read model).
CREATE TABLE leave (
  engineer_id int NOT NULL,
  kind        text NOT NULL,
  valid_at    daterange NOT NULL,
  PRIMARY KEY (engineer_id, valid_at WITHOUT OVERLAPS),
  FOREIGN KEY (engineer_id, PERIOD valid_at) REFERENCES employment (engineer_id, PERIOD valid_at)
);

-- "hours logged"; a logged day must be covered by an allocation (ADR-008).
CREATE TABLE timesheet (
  engineer_id int NOT NULL,
  project_id  int NOT NULL,
  work_day    daterange NOT NULL,
  hours       numeric(4,2) NOT NULL CHECK (hours > 0 AND hours <= 24),
  PRIMARY KEY (engineer_id, project_id, work_day WITHOUT OVERLAPS),
  FOREIGN KEY (engineer_id, project_id, PERIOD work_day)
    REFERENCES allocation (engineer_id, project_id, PERIOD valid_at)
);
