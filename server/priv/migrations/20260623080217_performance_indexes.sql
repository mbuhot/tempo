-- 20260623080217_performance_indexes.sql — secondary indexes for the as-of reads,
-- and real surrogate primary keys for the two snapshot line tables (#8).
--
-- The schema (001_schema.sql) ships with ZERO explicit secondary indexes. Every
-- as-of read is a sequential-scan range join; board.snapshot fires five of them.
-- Correctness is unaffected — these only change plans — so the read tests stay
-- green; this file is purely additive (expand step, never edits 001).
--
-- Three index families, mirroring the issue:
--   * GiST on the `*_during` range columns probed by @>/&& in the as-of joins.
--     The WITHOUT OVERLAPS primary keys already cover (scalar…, range), but a
--     query that constrains the range WITHOUT pinning the leading scalar (e.g.
--     a bare `held_during @> $1`) cannot use the composite PK's leading column,
--     so a range-leading GiST index is what the planner can probe.
--   * btree on the scalar join/filter columns the joins equate on, and on every
--     `audit_id` provenance FK (so provenance lookups and the FK's own integrity
--     checks do not scan).
--   * Surrogate PKs for invoice_line / payroll_line (previously PK-less heaps),
--     plus btree on their parent FKs so header→lines fan-out is an index scan.

-- GiST on the semantic-period range columns used in @>/&& as-of probes ---------
CREATE INDEX allocation_allocated_during_gist   ON allocation     USING gist (allocated_during);
CREATE INDEX employment_employed_during_gist    ON employment     USING gist (employed_during);
CREATE INDEX engineer_role_held_during_gist     ON engineer_role  USING gist (held_during);
CREATE INDEX rate_card_effective_during_gist    ON rate_card      USING gist (effective_during);
CREATE INDEX salary_effective_during_gist       ON salary         USING gist (effective_during);
CREATE INDEX project_run_active_during_gist     ON project_run    USING gist (active_during);
CREATE INDEX leave_on_leave_during_gist         ON leave          USING gist (on_leave_during);
CREATE INDEX contract_terms_term_gist           ON contract_terms USING gist (term);
CREATE INDEX project_requirement_required_during_gist
  ON project_requirement USING gist (required_during);
CREATE INDEX invoice_subject_billing_period_gist ON invoice_subject USING gist (billing_period);

-- btree on the scalar columns the as-of joins equate on -----------------------
CREATE INDEX engineer_role_engineer_id_idx ON engineer_role (engineer_id);
CREATE INDEX engineer_role_level_idx       ON engineer_role (level);
CREATE INDEX rate_card_level_idx           ON rate_card (level);
CREATE INDEX salary_level_idx              ON salary (level);
CREATE INDEX leave_engineer_id_idx         ON leave (engineer_id);
CREATE INDEX leave_policy_kind_level_idx   ON leave_policy (kind, level);
CREATE INDEX allocation_project_id_idx     ON allocation (project_id);
CREATE INDEX project_run_contract_id_idx   ON project_run (contract_id);
CREATE INDEX project_requirement_project_id_idx ON project_requirement (project_id);
CREATE INDEX contract_terms_client_id_idx  ON contract_terms (client_id);
CREATE INDEX timesheet_project_id_idx      ON timesheet (project_id);
CREATE INDEX invoice_subject_project_id_idx ON invoice_subject (project_id);
CREATE INDEX invoice_status_invoice_id_idx ON invoice_status (invoice_id);

-- btree on every audit_id provenance FK (one per fact table that carries it) ---
CREATE INDEX employment_audit_id_idx          ON employment (audit_id);
CREATE INDEX engineer_role_audit_id_idx       ON engineer_role (audit_id);
CREATE INDEX engineer_contact_audit_id_idx    ON engineer_contact (audit_id);
CREATE INDEX engineer_banking_audit_id_idx    ON engineer_banking (audit_id);
CREATE INDEX engineer_emergency_audit_id_idx  ON engineer_emergency (audit_id);
CREATE INDEX leave_audit_id_idx               ON leave (audit_id);
CREATE INDEX contract_terms_audit_id_idx      ON contract_terms (audit_id);
CREATE INDEX project_run_audit_id_idx         ON project_run (audit_id);
CREATE INDEX project_profile_audit_id_idx     ON project_profile (audit_id);
CREATE INDEX project_plan_audit_id_idx        ON project_plan (audit_id);
CREATE INDEX allocation_audit_id_idx          ON allocation (audit_id);
CREATE INDEX project_requirement_audit_id_idx ON project_requirement (audit_id);
CREATE INDEX timesheet_audit_id_idx           ON timesheet (audit_id);
CREATE INDEX client_profile_audit_id_idx      ON client_profile (audit_id);
CREATE INDEX rate_card_audit_id_idx           ON rate_card (audit_id);
CREATE INDEX salary_audit_id_idx              ON salary (audit_id);
CREATE INDEX leave_policy_audit_id_idx        ON leave_policy (audit_id);
CREATE INDEX invoice_subject_audit_id_idx     ON invoice_subject (audit_id);
CREATE INDEX invoice_status_audit_id_idx      ON invoice_status (audit_id);
CREATE INDEX invoice_line_audit_id_idx        ON invoice_line (audit_id);
CREATE INDEX payroll_period_audit_id_idx      ON payroll_period (audit_id);
CREATE INDEX payroll_line_audit_id_idx        ON payroll_line (audit_id);

-- Real surrogate PKs for the snapshot line tables -----------------------------
-- Both shipped as PK-less heaps. A surrogate id gives each line a stable handle;
-- the parent-FK btrees make header→lines fan-out an index scan, not a seq scan.
ALTER TABLE invoice_line ADD COLUMN id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY;
ALTER TABLE payroll_line ADD COLUMN id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY;

CREATE INDEX invoice_line_invoice_id_idx ON invoice_line (invoice_id);
CREATE INDEX payroll_line_run_id_idx     ON payroll_line (run_id);
