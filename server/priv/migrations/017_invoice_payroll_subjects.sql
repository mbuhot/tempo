-- 017_invoice_payroll_subjects.sql — split invoice and payroll_run into an ID-ONLY
-- anchor + a 1:1 IMMUTABLE fact, the financial-layer counterpart of the
-- engineer/client/contract/project anchor refactors (014–016).
--
-- Unlike those facts, invoice's remaining columns (project_id, billing_period) and
-- payroll_run's (period) are a SUBJECT set once at draft / run and never changed —
-- not a versioned valid-time history. So there is exactly ONE fact row per anchor
-- (keyed by the anchor PK, not a WITHOUT OVERLAPS period PK) and NO *_current view:
-- reads INNER JOIN the fact directly.
--
-- The columns MOVE TABLES here (they are not renamed in place), so the constraints
-- that key against them do NOT auto-follow — they are DROPPED from the anchor and
-- RE-ADDED on the 1:1 fact:
--   * invoice_within_project (PERIOD FK to project_run) and invoice_project_fkey
--     (plain FK to project) both reference columns that move to invoice_subject.
--   * payroll_run_no_overlap (the GiST exclusion on period) keys against period,
--     which moves to payroll_period.

-- invoice -> anchor + subject --------------------------------------------------
-- Drop both FKs that key against the moving columns, mint the immutable
-- invoice_subject (1:1 with the invoice anchor), copy the rows, re-add the PERIOD
-- and plain project FKs on the fact, then drop the moved columns from the anchor.
ALTER TABLE invoice DROP CONSTRAINT invoice_within_project;
ALTER TABLE invoice DROP CONSTRAINT invoice_project_fkey;
CREATE TABLE invoice_subject (
  invoice_id     int PRIMARY KEY REFERENCES invoice(id),
  project_id     int NOT NULL REFERENCES project(id),
  billing_period daterange NOT NULL,
  CONSTRAINT invoice_subject_within_project
    FOREIGN KEY (project_id, PERIOD billing_period) REFERENCES project_run(project_id, PERIOD active_during)
);
INSERT INTO invoice_subject (invoice_id, project_id, billing_period)
  SELECT id, project_id, billing_period FROM invoice;
ALTER TABLE invoice DROP COLUMN project_id;
ALTER TABLE invoice DROP COLUMN billing_period;

-- payroll_run -> anchor + period -----------------------------------------------
-- Drop the no-overlap exclusion (it keys against period), mint the immutable
-- payroll_period (1:1 with the run anchor) carrying that exclusion, copy the rows,
-- then drop the moved column from the anchor.
ALTER TABLE payroll_run DROP CONSTRAINT payroll_run_no_overlap;
CREATE TABLE payroll_period (
  run_id int PRIMARY KEY REFERENCES payroll_run(id),
  period daterange NOT NULL,
  CONSTRAINT payroll_period_no_overlap EXCLUDE USING gist (period WITH &&)
);
INSERT INTO payroll_period (run_id, period) SELECT id, period FROM payroll_run;
ALTER TABLE payroll_run DROP COLUMN period;
