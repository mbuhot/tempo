-- scale_seed.sql — a deterministic, index-scale synthetic dataset for the perf
-- gate (issue #20): 500 engineers, 150 clients/contracts, 200 projects, rolling
-- allocations, leave, monthly payroll, and invoices.
--
-- NOT an auto-applied migration, and NOT the dev demo cast — it lives outside
-- priv/migrations and is applied only by `tempo/seed_scale` (`bin/seed-scale`)
-- against its own dedicated database (`tempo_perf`), never `tempo`/`tempo_test*`/
-- `tempo_e2e*`. Every value is a pure function of a generated series index (engineer
-- number, project number, calendar month, ...) — no randomness, no clock reads — so
-- re-running the generator from an empty database reproduces byte-identical data.
--
-- Every event_log row this file writes is at an EXPLICIT id (`OVERRIDING SYSTEM
-- VALUE` — event_log is a GENERATED ALWAYS identity), so every later fact
-- statement can reference a fixed audit_id by literal rather than threading a
-- RETURNING value across statement boundaries (sequences are not transactional,
-- so a literal is the only id a later, separate statement can rely on). The
-- non-event_log anchors (engineer, client, contract, project, invoice,
-- payroll_run) are BY DEFAULT identities, so they take explicit ids the same way
-- the base demo seed's anchors do, each followed by a `setval` catch-up.
--
-- One phase-per-command-kind event_log row is minted (not one per fact row),
-- exactly mirroring how a real bulk-ish command's provenance would look: every
-- fact row from that phase shares its audit_id.
INSERT INTO event_log (id, occurred_at, actor, operation, summary, payload)
OVERRIDING SYSTEM VALUE
VALUES
  (1,  '2024-01-01', 'seed_scale', 'revise_rate_card',        'Bulk-establish rate card L1-L7 from 2024-01-01', '{}'),
  (2,  '2024-01-01', 'seed_scale', 'set_salary',              'Bulk-set salaries L1-L7 from 2024-01-01', '{}'),
  (3,  '2024-01-01', 'seed_scale', 'set_leave_policy',        'Bulk-set leave policy (annual/sick) from 2024-01-01', '{}'),
  (4,  '2024-01-01', 'seed_scale', 'register_client',         'Bulk-register 150 perf clients', '{}'),
  (5,  '2024-01-01', 'seed_scale', 'onboard_engineer',        'Bulk-onboard 500 perf engineers (employment + contact)', '{}'),
  (6,  '2024-01-01', 'seed_scale', 'set_engineer_role',       'Bulk-set opening engineer roles', '{}'),
  (7,  '2024-01-01', 'seed_scale', 'promote',                 'Bulk promotions every ~18 months', '{}'),
  (8,  '2024-01-01', 'seed_scale', 'sign_contract',           'Bulk-sign 150 perf contracts', '{}'),
  (9,  '2024-01-01', 'seed_scale', 'start_project',           'Bulk-start 200 perf projects (run + profile + plan)', '{}'),
  (10, '2024-01-01', 'seed_scale', 'set_project_requirement', 'Bulk-set project capacity requirements', '{}'),
  (11, '2024-01-01', 'seed_scale', 'assign_to_project',       'Bulk rolling allocations, reshuffled every 4 months', '{}'),
  (12, '2024-01-01', 'seed_scale', 'take_leave',              'Bulk annual/sick leave, 2 per engineer per year', '{}');

-- Rate card / salary / leave policy: flat per level (1-7), open-ended from
-- 2024-01-01 — every measured as-of read joins through one of these three, so
-- they must cover every date the perf gate probes.
INSERT INTO rate_card (level, day_rate, effective_during, audit_id)
SELECT level, (level * 200)::numeric(10,2), daterange('2024-01-01', NULL), 1
FROM generate_series(1, 7) AS level;

INSERT INTO salary (level, monthly_salary, effective_during, audit_id)
SELECT level, (level * 2000)::numeric(10,2), daterange('2024-01-01', NULL), 2
FROM generate_series(1, 7) AS level;

INSERT INTO leave_policy (kind, level, days_per_year, effective_during, audit_id)
SELECT kind, level,
       CASE WHEN kind = 'annual' AND level <= 5 THEN 20.00
            WHEN kind = 'annual' THEN 25.00
            ELSE 10.00 END,
       daterange('2024-01-01', NULL), 3
FROM generate_series(1, 7) AS level, (VALUES ('annual'), ('sick')) AS k(kind);

-- Clients (150) + client_profile, named Perf Client 00001.. .
INSERT INTO client (id) SELECT generate_series(1, 150);
SELECT setval(pg_get_serial_sequence('client', 'id'), 150);

INSERT INTO client_profile (client_id, name, recorded_during, audit_id)
SELECT i, 'Perf Client ' || lpad(i::text, 5, '0'), daterange('2024-01-01', NULL), 4
FROM generate_series(1, 150) AS i;

-- Engineers (500), named Perf Engineer 00001.. . Employment start staggers
-- weekly across a 2-year cycle from 2024-01-01, every engineer runs to the
-- fixed 2027-01-01 horizon.
INSERT INTO engineer (id) SELECT generate_series(1, 500);
SELECT setval(pg_get_serial_sequence('engineer', 'id'), 500);

INSERT INTO employment (engineer_id, employed_during, audit_id)
SELECT i, daterange((date '2024-01-01' + (((i - 1) % 104) * 7))::date, '2027-01-01', '[)'), 5
FROM generate_series(1, 500) AS i;

INSERT INTO engineer_contact (engineer_id, name, email, phone, postal_address, recorded_during, audit_id)
SELECT i, 'Perf Engineer ' || lpad(i::text, 5, '0'),
       'perf.engineer.' || lpad(i::text, 5, '0') || '@example.test',
       '+61 400 ' || lpad(i::text, 6, '0'),
       lpad(i::text, 5, '0') || ' Demo St, Brisbane',
       daterange((date '2024-01-01' + (((i - 1) % 104) * 7))::date, NULL),
       5
FROM generate_series(1, 500) AS i;

-- engineer_role: an opening level 1 + (i % 6), then a promotion roughly every 18
-- months (capped at level 7 and at the 2027-01-01 employment horizon). Segment
-- boundaries are chained with `lead()` so each engineer's role periods are
-- contiguous and non-overlapping by construction.
WITH e AS (
  SELECT i AS engineer_id,
         (date '2024-01-01' + (((i - 1) % 104) * 7))::date AS start_date,
         1 + (i % 6) AS opening_level
  FROM generate_series(1, 500) AS i
),
boundaries AS (
  SELECT e.engineer_id, e.opening_level, k,
         (e.start_date + (k * 18 * interval '1 month'))::date AS seg_start
  FROM e, generate_series(0, 2) AS k
  WHERE k = 0
     OR ( (e.start_date + (k * 18 * interval '1 month'))::date < date '2027-01-01'
          AND e.opening_level + k <= 7 )
),
segments AS (
  SELECT engineer_id, k, opening_level + k AS level, seg_start,
         lead(seg_start) OVER (PARTITION BY engineer_id ORDER BY k) AS seg_end
  FROM boundaries
)
INSERT INTO engineer_role (engineer_id, level, held_during, audit_id)
SELECT engineer_id, level,
       daterange(seg_start, coalesce(seg_end, date '2027-01-01'), '[)'),
       CASE WHEN k = 0 THEN 6 ELSE 7 END
FROM segments;

-- Contracts (150) + contract_terms: start staggers by calendar month across
-- 2024, every term runs to the fixed 2027-01-01 horizon (client_id = contract_id,
-- a 1:1 mapping).
INSERT INTO contract (id) SELECT generate_series(1, 150);
SELECT setval(pg_get_serial_sequence('contract', 'id'), 150);

INSERT INTO contract_terms (contract_id, client_id, term, audit_id)
SELECT i, i,
       daterange((date '2024-01-01' + ((i - 1) % 12) * interval '1 month')::date, '2027-01-01', '[)'),
       8
FROM generate_series(1, 150) AS i;

-- Projects (200), cycling through the 150 contracts. A project's run is exactly
-- its contract's span (trivially contained by the PERIOD FK), profile/plan carry
-- the same start. run + profile + plan chain through one statement (base_seed's
-- per-project WITH-chained-INSERT pattern, generalised to a series).
INSERT INTO project (id) SELECT generate_series(1, 200);
SELECT setval(pg_get_serial_sequence('project', 'id'), 200);

WITH base AS (
  SELECT j AS project_id, ((j - 1) % 150) + 1 AS contract_id,
         (date '2024-01-01' + (((j - 1) % 150) % 12) * interval '1 month')::date AS start_date
  FROM generate_series(1, 200) AS j
),
run AS (
  INSERT INTO project_run (project_id, contract_id, active_during, audit_id)
  SELECT project_id, contract_id, daterange(start_date, '2027-01-01', '[)'), 9 FROM base
  RETURNING project_id
),
prof AS (
  INSERT INTO project_profile (project_id, title, summary, recorded_during, audit_id)
  SELECT project_id, 'Perf Project ' || lpad(project_id::text, 5, '0'), '', daterange(start_date, NULL), 9
  FROM base
  RETURNING project_id
)
INSERT INTO project_plan (project_id, budget, target_completion, planned_during, audit_id)
SELECT project_id, (100000 + (project_id % 10) * 50000)::numeric(12,2), '2026-12-31', daterange(start_date, NULL), 9
FROM base;

-- project_requirement: 3-5 versioned rows per project, one per level, spanning
-- the run. `level = 1 + ((project_id + k) % 7)` over k = 0..(count-1) with
-- count <= 5 guarantees distinct levels (5 consecutive residues mod 7 never
-- collide).
WITH base AS (
  SELECT j AS project_id,
         (date '2024-01-01' + (((j - 1) % 150) % 12) * interval '1 month')::date AS start_date
  FROM generate_series(1, 200) AS j
)
INSERT INTO project_requirement (project_id, level, quantity, required_during, audit_id)
SELECT base.project_id, 1 + ((base.project_id + k) % 7), (1.0 + 0.5 * (k % 3))::numeric(4,2),
       daterange(base.start_date, '2027-01-01', '[)'), 10
FROM base, generate_series(0, 4) AS k
WHERE k < (3 + (base.project_id % 3));

-- Allocations: a rolling assignment re-shuffled every 4 months, 6 concurrent
-- slots per period (an engineer typically splits across a small bench of
-- projects, generalising the demo's 0.5+0.5 split). 6 rather than the minimum
-- needed for the row-count target alone: it also keeps invoice_line large
-- enough that the perf gate's planted-regression check (dropping
-- invoice_line_invoice_id_idx) produces a measurable, not just directional,
-- regression — see docs/2026-07-08-perf-findings.md. Slot s's project index
-- offset (s * 33) keeps all of an engineer's (period, slot) project ids distinct
-- (six disjoint 9-wide residue bands mod 200), so no engineer is ever assigned
-- the same project twice. Each period/slot's window is clipped to its project's
-- active run (`*`, the range-intersection operator) and dropped if that leaves
-- nothing (NOT isempty) — satisfying the allocation_within_project PERIOD FK by
-- construction rather than by care with the offsets.
WITH e AS (
  SELECT i AS engineer_id,
         (date '2024-01-01' + (((i - 1) % 104) * 7))::date AS start_date
  FROM generate_series(1, 500) AS i
),
periods AS (
  SELECT e.engineer_id, e.start_date, p,
         (e.start_date + (p * 4 * interval '1 month'))::date AS seg_start,
         LEAST((e.start_date + ((p + 1) * 4 * interval '1 month'))::date, date '2027-01-01') AS seg_end
  FROM e, generate_series(0, 8) AS p
  WHERE (e.start_date + (p * 4 * interval '1 month'))::date < date '2027-01-01'
),
assigned AS (
  SELECT engineer_id, p, s, seg_start, seg_end,
         1 + ((engineer_id + p + s * 33) % 200) AS project_id,
         (ARRAY[0.5, 0.8, 1.0])[((p + s) % 3) + 1] AS fraction
  FROM periods, generate_series(0, 5) AS s
),
clipped AS (
  SELECT a.engineer_id, a.project_id, a.fraction,
         daterange(a.seg_start, a.seg_end, '[)') * pr.active_during AS alloc_range
  FROM assigned a
  JOIN project_run pr ON pr.project_id = a.project_id
  WHERE NOT isempty(daterange(a.seg_start, a.seg_end, '[)') * pr.active_during)
)
INSERT INTO allocation (engineer_id, project_id, fraction, allocated_during, audit_id)
SELECT engineer_id, project_id, fraction, alloc_range, 11
FROM clipped;

-- Leave: an annual block (March) and a sick block (September) each of the three
-- seed years, clipped to employment (`*` / NOT isempty again) so an engineer
-- hired mid-cycle simply loses the blocks that predate their start rather than
-- violating leave_within_employment. The two kinds' blocks are 6 months apart
-- every year, so they never overlap each other under the leave_no_overlap
-- exclusion constraint.
WITH e AS (
  SELECT i AS engineer_id,
         (date '2024-01-01' + (((i - 1) % 104) * 7))::date AS start_date
  FROM generate_series(1, 500) AS i
),
raw AS (
  SELECT e.engineer_id, k.kind,
         daterange(make_date(y.year, k.month, k.day), make_date(y.year, k.month, k.day) + k.span_days, '[)')
           * daterange(e.start_date, '2027-01-01') AS leave_range
  FROM e, (VALUES (2024), (2025), (2026)) AS y(year),
       (VALUES ('annual', 3, 1, 7), ('sick', 9, 1, 3)) AS k(kind, month, day, span_days)
)
INSERT INTO leave (engineer_id, kind, on_leave_during, audit_id)
SELECT engineer_id, kind, leave_range, 12
FROM raw
WHERE NOT isempty(leave_range);

-- Payroll: one event_log row per calendar month (ids 13..42) plus three more for
-- the invoice lifecycle phases (43..45) — both minted here, at explicit ids,
-- continuing the phase-1..12 batch above.
INSERT INTO event_log (id, occurred_at, actor, operation, summary, payload)
OVERRIDING SYSTEM VALUE
SELECT 12 + m, (date '2024-01-01' + (m - 1) * interval '1 month')::timestamptz, 'seed_scale', 'run_payroll',
       'Bulk payroll run for ' || to_char(date '2024-01-01' + (m - 1) * interval '1 month', 'YYYY-MM'), '{}'
FROM generate_series(1, 30) AS m;

INSERT INTO event_log (id, occurred_at, actor, operation, summary, payload)
OVERRIDING SYSTEM VALUE
VALUES
  (43, '2026-01-01', 'seed_scale', 'create_invoice', 'Bulk-create perf invoices (opened draft)', '{}'),
  (44, '2026-01-01', 'seed_scale', 'issue_invoice',  'Bulk-issue perf invoices', '{}'),
  (45, '2026-01-01', 'seed_scale', 'pay_invoice',    'Bulk-pay perf invoices', '{}');

SELECT setval(pg_get_serial_sequence('event_log', 'id'), 45);

-- payroll_run anchors: one monthly run from 2024-01 to 2026-06 (30 runs).
INSERT INTO payroll_run (id) SELECT generate_series(1, 30);
SELECT setval(pg_get_serial_sequence('payroll_run', 'id'), 30);

-- payroll_period + payroll_line + payroll_line_segment, computed by reusing the
-- schema's own proration kernels (prorated_salary / range_days, defined in
-- 20260623081652_proration_kernels_and_current_views.sql) over the
-- already-seeded employment / engineer_role / salary facts — the same formula
-- payroll_amounts.sql runs at request time, so a run's numbers are exactly what
-- the real endpoint would have computed.
WITH months AS (
  SELECT m AS run_id,
         (date '2024-01-01' + (m - 1) * interval '1 month')::date AS month_start,
         (date '2024-01-01' + m * interval '1 month')::date AS month_end,
         12 + m AS audit_id
  FROM generate_series(1, 30) AS m
),
period_ins AS (
  INSERT INTO payroll_period (run_id, period, audit_id)
  SELECT run_id, daterange(month_start, month_end, '[)'), audit_id FROM months
  RETURNING run_id
),
sub AS (
  SELECT months.run_id, months.audit_id, employment.engineer_id, engineer_role.level,
         salary.monthly_salary,
         employment.employed_during * engineer_role.held_during * salary.effective_during
           * daterange(months.month_start, months.month_end, '[)') AS sub_period,
         daterange(months.month_start, months.month_end, '[)') AS month_span
  FROM months
  JOIN employment ON employment.employed_during && daterange(months.month_start, months.month_end, '[)')
  JOIN engineer_role ON engineer_role.engineer_id = employment.engineer_id
                    AND engineer_role.held_during && employment.employed_during
                    AND engineer_role.held_during && daterange(months.month_start, months.month_end, '[)')
  JOIN salary ON salary.level = engineer_role.level
             AND salary.effective_during && engineer_role.held_during
             AND salary.effective_during && daterange(months.month_start, months.month_end, '[)')
  WHERE NOT isempty(employment.employed_during * engineer_role.held_during * salary.effective_during
                     * daterange(months.month_start, months.month_end, '[)'))
),
line_ins AS (
  INSERT INTO payroll_line (run_id, engineer_id, amount, days, audit_id)
  SELECT run_id, engineer_id,
         sum(prorated_salary(monthly_salary, sub_period, month_span))::numeric(12,2),
         sum(range_days(sub_period))::numeric(8,2), audit_id
  FROM sub
  GROUP BY run_id, engineer_id, audit_id
  RETURNING run_id
)
INSERT INTO payroll_line_segment (run_id, engineer_id, level, monthly_salary, days, amount, audit_id)
SELECT run_id, engineer_id, level, monthly_salary,
       range_days(sub_period)::numeric(8,2),
       prorated_salary(monthly_salary, sub_period, month_span)::numeric(12,2),
       audit_id
FROM sub;

-- Invoices: one per (project, month) that has any allocation, over 2025-01..
-- 2026-06 (18 months). Every third invoice (by id) stays draft, every third
-- reaches issued, every third reaches paid — status_during spans are
-- constructed directly (draft -> issued -> paid), never overlapping. The
-- (project, month) numbering is recomputed identically in each statement below
-- (a pure function of already-seeded project_run/allocation), so invoice,
-- invoice_subject, invoice_status and invoice_line agree on the same invoice_id
-- without threading it through a temp table.
INSERT INTO invoice (id)
WITH invoice_months AS (
  SELECT m AS month_idx,
         (date '2025-01-01' + (m - 1) * interval '1 month')::date AS month_start,
         (date '2025-01-01' + m * interval '1 month')::date AS month_end
  FROM generate_series(1, 18) AS m
),
candidates AS (
  SELECT DISTINCT project_run.project_id, invoice_months.month_idx
  FROM project_run
  CROSS JOIN invoice_months
  WHERE EXISTS (
    SELECT 1 FROM allocation
     WHERE allocation.project_id = project_run.project_id
       AND allocation.allocated_during && daterange(invoice_months.month_start, invoice_months.month_end, '[)')
  )
)
SELECT row_number() OVER (ORDER BY project_id, month_idx) FROM candidates;

SELECT setval(pg_get_serial_sequence('invoice', 'id'), (SELECT max(id) FROM invoice));

WITH invoice_months AS (
  SELECT m AS month_idx,
         (date '2025-01-01' + (m - 1) * interval '1 month')::date AS month_start,
         (date '2025-01-01' + m * interval '1 month')::date AS month_end
  FROM generate_series(1, 18) AS m
),
candidates AS (
  SELECT DISTINCT project_run.project_id, invoice_months.month_idx
  FROM project_run
  CROSS JOIN invoice_months
  WHERE EXISTS (
    SELECT 1 FROM allocation
     WHERE allocation.project_id = project_run.project_id
       AND allocation.allocated_during && daterange(invoice_months.month_start, invoice_months.month_end, '[)')
  )
),
numbered AS (
  SELECT row_number() OVER (ORDER BY c.project_id, c.month_idx) AS invoice_id,
         c.project_id, im.month_start, im.month_end
  FROM candidates c
  JOIN invoice_months im ON im.month_idx = c.month_idx
),
subj AS (
  INSERT INTO invoice_subject (invoice_id, project_id, billing_period, audit_id)
  SELECT invoice_id, project_id, daterange(month_start, month_end, '[)'), 43
  FROM numbered
  RETURNING invoice_id
),
draft_ins AS (
  INSERT INTO invoice_status (invoice_id, status, status_during, audit_id)
  SELECT invoice_id, 'draft',
         CASE WHEN (invoice_id % 3) = 0 THEN daterange(month_start, NULL)
              ELSE daterange(month_start, month_start + 5, '[)') END,
         43
  FROM numbered
  RETURNING invoice_id
),
issued_ins AS (
  INSERT INTO invoice_status (invoice_id, status, status_during, audit_id)
  SELECT invoice_id, 'issued',
         CASE WHEN (invoice_id % 3) = 1 THEN daterange(month_start + 5, NULL)
              ELSE daterange(month_start + 5, month_start + 20, '[)') END,
         44
  FROM numbered
  WHERE (invoice_id % 3) IN (1, 2)
  RETURNING invoice_id
)
INSERT INTO invoice_status (invoice_id, status, status_during, audit_id)
SELECT invoice_id, 'paid', daterange(month_start + 20, NULL), 45
FROM numbered
WHERE (invoice_id % 3) = 2;

-- invoice_line: one line per engineer allocated to the invoice's project during
-- its billing month, priced at that month's rate_card for the engineer's level.
-- Days are a flat approximate 20 billable days/month — the perf gate only needs
-- realistic row counts, not exact billing amounts.
--
-- allocation_months (allocation joined to its overlapping billing months) is
-- computed FIRST, so the allocation table's own GiST index drives the fan-out
-- before engineer_role/rate_card ever enter the plan. Joining engineer_role/
-- rate_card straight off `numbered` (as project_invoices.sql's shape might
-- suggest) starves the planner of a cardinality estimate for the CTE and it
-- picks a nested loop over ALL engineer_role rows active that month before
-- filtering by project — fine at demo scale, ~20x slower at this one (17s vs
-- <1s), so the join order here is load-bearing, not stylistic.
WITH invoice_months AS (
  SELECT m AS month_idx,
         (date '2025-01-01' + (m - 1) * interval '1 month')::date AS month_start,
         (date '2025-01-01' + m * interval '1 month')::date AS month_end
  FROM generate_series(1, 18) AS m
),
allocation_months AS (
  SELECT allocation.project_id, allocation.engineer_id, allocation.fraction,
         invoice_months.month_idx, invoice_months.month_start, invoice_months.month_end
  FROM allocation
  JOIN invoice_months
    ON allocation.allocated_during && daterange(invoice_months.month_start, invoice_months.month_end, '[)')
),
numbered AS (
  SELECT row_number() OVER (ORDER BY project_id, month_idx) AS invoice_id, project_id, month_idx
  FROM (SELECT DISTINCT project_id, month_idx FROM allocation_months) AS candidates
)
INSERT INTO invoice_line (invoice_id, engineer_id, level, day_rate, days, amount, audit_id)
SELECT numbered.invoice_id, am.engineer_id, engineer_role.level, rate_card.day_rate,
       20::numeric(8,2),
       (am.fraction * rate_card.day_rate * 20)::numeric(12,2),
       43
FROM allocation_months am
JOIN numbered ON numbered.project_id = am.project_id AND numbered.month_idx = am.month_idx
JOIN engineer_role ON engineer_role.engineer_id = am.engineer_id
                  AND engineer_role.held_during @> am.month_start
JOIN rate_card ON rate_card.level = engineer_role.level
              AND rate_card.effective_during @> am.month_start;

-- Freshen the planner's statistics on every touched table before any EXPLAIN
-- ANALYZE run against this database.
ANALYZE engineer;
ANALYZE employment;
ANALYZE engineer_contact;
ANALYZE engineer_role;
ANALYZE client;
ANALYZE client_profile;
ANALYZE contract;
ANALYZE contract_terms;
ANALYZE project;
ANALYZE project_run;
ANALYZE project_profile;
ANALYZE project_plan;
ANALYZE project_requirement;
ANALYZE allocation;
ANALYZE leave;
ANALYZE rate_card;
ANALYZE salary;
ANALYZE leave_policy;
ANALYZE payroll_run;
ANALYZE payroll_period;
ANALYZE payroll_line;
ANALYZE payroll_line_segment;
ANALYZE invoice;
ANALYZE invoice_subject;
ANALYZE invoice_status;
ANALYZE invoice_line;
ANALYZE event_log;
