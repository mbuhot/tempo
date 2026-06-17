-- 002_facts.sql — the eight fact tables (v1-wide schema; ARCHITECTURE.md §4, §7).
--
-- Each fact is a narrow relation valid over its own `daterange` period column
-- (per-fact: employed_during, held_during, effective_during, term, active_during,
-- allocated_during, on_leave_during, work_day) (ADR-004).
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
  employed_during daterange NOT NULL,
  CONSTRAINT employment_no_overlap
    PRIMARY KEY (engineer_id, employed_during WITHOUT OVERLAPS)
);

-- "engineer is at level L"; a promotion is a new row, not an UPDATE (ADR-009).
CREATE TABLE engineer_role (
  engineer_id int NOT NULL,
  level       int NOT NULL CHECK (level BETWEEN 1 AND 7),
  held_during daterange NOT NULL,
  CONSTRAINT engineer_role_no_overlap
    PRIMARY KEY (engineer_id, held_during WITHOUT OVERLAPS),
  CONSTRAINT engineer_role_within_employment
    FOREIGN KEY (engineer_id, PERIOD held_during)
    REFERENCES employment (engineer_id, PERIOD employed_during)
);

-- L1–L7 charge rates, versioned over time; the FOR PORTION OF target (ADR-009).
CREATE TABLE rate_card (
  level    int NOT NULL CHECK (level BETWEEN 1 AND 7),
  day_rate numeric(10,2) NOT NULL,
  effective_during daterange NOT NULL,
  CONSTRAINT rate_card_no_overlap
    PRIMARY KEY (level, effective_during WITHOUT OVERLAPS)
);

-- "client engagement", a term.
CREATE TABLE contract (
  id        int NOT NULL,
  client_id int NOT NULL REFERENCES client(id),
  term      daterange NOT NULL,
  CONSTRAINT contract_no_overlap
    PRIMARY KEY (id, term WITHOUT OVERLAPS)
);

-- "project runs under a contract" (project ⊂ contract).
CREATE TABLE project (
  id          int NOT NULL,
  contract_id int NOT NULL,
  name        text NOT NULL,
  active_during daterange NOT NULL,
  CONSTRAINT project_no_overlap
    PRIMARY KEY (id, active_during WITHOUT OVERLAPS),
  CONSTRAINT project_within_contract
    FOREIGN KEY (contract_id, PERIOD active_during)
    REFERENCES contract (id, PERIOD term)
);

-- "engineer on project" (fractional; ⊂ employment AND ⊂ project).
-- v1-wide: `day_rate` caches the engineer's charge rate for the period so
-- billing need not join engineer_role × rate_card. Removed in v2-split.
CREATE TABLE allocation (
  engineer_id int NOT NULL,
  project_id  int NOT NULL,
  fraction    numeric(3,2) NOT NULL CHECK (fraction > 0 AND fraction <= 1),
  day_rate    numeric(10,2) NOT NULL,
  allocated_during daterange NOT NULL,
  CONSTRAINT allocation_no_overlap
    PRIMARY KEY (engineer_id, project_id, allocated_during WITHOUT OVERLAPS),
  CONSTRAINT allocation_within_employment
    FOREIGN KEY (engineer_id, PERIOD allocated_during)
    REFERENCES employment (engineer_id, PERIOD employed_during),
  CONSTRAINT allocation_within_project
    FOREIGN KEY (project_id,  PERIOD allocated_during)
    REFERENCES project    (id,          PERIOD active_during)
);

-- "engineer on leave" (⊂ employment; overrides allocation in the read model).
CREATE TABLE leave (
  engineer_id int NOT NULL,
  kind        text NOT NULL,
  on_leave_during daterange NOT NULL,
  CONSTRAINT leave_no_overlap
    PRIMARY KEY (engineer_id, on_leave_during WITHOUT OVERLAPS),
  CONSTRAINT leave_within_employment
    FOREIGN KEY (engineer_id, PERIOD on_leave_during)
    REFERENCES employment (engineer_id, PERIOD employed_during)
);

-- "hours logged"; a logged day must be covered by an allocation (ADR-008).
CREATE TABLE timesheet (
  engineer_id int NOT NULL,
  project_id  int NOT NULL,
  work_day    daterange NOT NULL,
  hours       numeric(4,2) NOT NULL CHECK (hours > 0 AND hours <= 24),
  CONSTRAINT timesheet_no_overlap
    PRIMARY KEY (engineer_id, project_id, work_day WITHOUT OVERLAPS),
  CONSTRAINT timesheet_within_allocation
    FOREIGN KEY (engineer_id, project_id, PERIOD work_day)
    REFERENCES allocation (engineer_id, project_id, PERIOD allocated_during)
);
