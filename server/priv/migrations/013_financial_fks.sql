-- 013_financial_fks.sql — enforce the financial layer's cross-references that
-- 012 left to the computing queries (PRD-financials §8 / ADR-026 had declined
-- them; this migration adds the ones that are both feasible and worthwhile).
--
-- Three previously-unconstrained references become enforced:
--
--   * invoice.project_id — a temporal PERIOD foreign key into project's temporal
--     primary key, so an invoice's billing month must lie within the project's
--     active period: you can no longer draft an invoice for a project that did not
--     exist, or was not active, that month (previously it silently produced an
--     invoice with zero lines). A *plain* FK is impossible here — project's PK is
--     (id, active_during WITHOUT OVERLAPS), so `id` alone is not unique — but a
--     PERIOD FK keys against that temporal PK. The `_within_` name classifies a
--     violation as ContainmentViolated, like the other containment FKs.
--
--   * invoice_line.engineer_id, payroll_line.engineer_id — plain foreign keys into
--     the engineer identity table. These snapshot lines are computed from
--     FK-constrained facts, so the ids can't be orphaned in practice; the
--     constraints make the snapshot ledger self-consistent rather than relying on
--     the write path alone.
--
-- All three validate against the founding seed (every billing month sits inside
-- its project's active window; every line engineer exists) and the on-demand
-- financial seed (tempo/seed_financials). The migration runner wraps this file in
-- one transaction, so a row that violated any of them would roll the whole file
-- back.

ALTER TABLE invoice
  ADD CONSTRAINT invoice_within_project
  FOREIGN KEY (project_id, PERIOD billing_period)
  REFERENCES project (id, PERIOD active_during);

ALTER TABLE invoice_line
  ADD CONSTRAINT invoice_line_engineer_fkey
  FOREIGN KEY (engineer_id) REFERENCES engineer (id);

ALTER TABLE payroll_line
  ADD CONSTRAINT payroll_line_engineer_fkey
  FOREIGN KEY (engineer_id) REFERENCES engineer (id);
