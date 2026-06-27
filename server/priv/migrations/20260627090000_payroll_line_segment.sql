-- 20260627090000_payroll_line_segment.sql — the per-level breakdown of a payroll
-- line, frozen at run time (#23).
--
-- payroll_line already records the TOTAL prorated salary owed each engineer for a
-- run. When an engineer is promoted (or has a salary revision) mid-month, that total
-- blends two salary levels — the per-level split is computed in payroll_amounts' sub
-- CTE (employment ∩ engineer_role(level) ∩ salary ∩ month) and then summed away. This
-- table keeps that split: one row per (run, engineer, level) sub-period, so a
-- completed run shows exactly the pro-rated days and salary recognised at each level.
-- The segments of a (run, engineer) sum back to its payroll_line total.
--
-- Additive (expand step): a new fact table only; it never edits the 001 baseline or
-- existing payroll rows.
CREATE TABLE payroll_line_segment (
  run_id         int NOT NULL REFERENCES payroll_run(id),
  engineer_id    int NOT NULL CONSTRAINT payroll_line_segment_engineer_fkey REFERENCES engineer(id),
  level          int NOT NULL CONSTRAINT payroll_line_segment_level_check CHECK (level BETWEEN 1 AND 7),
  monthly_salary numeric(10,2) NOT NULL,
  days           numeric(8,2)  NOT NULL,
  amount         numeric(12,2) NOT NULL
);

-- audit_id FK to the writing command's event_log entry, matching every other fact
-- table (ADR-032).
ALTER TABLE payroll_line_segment ADD COLUMN audit_id bigint REFERENCES event_log(id);
