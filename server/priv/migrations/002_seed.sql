-- 002_seed.sql — the deterministic demo seed, with realistic provenance.
--
-- Hand-written: explicit ids, names, dates, rates — no factory sequences. Consumed
-- unchanged by the as-of query tests and the Playwright suite, so it must stay stable.
-- Fixed seed "now" = 2026-06-15; the UI slider and every test anchor to it.
--
-- Each logical operation is one statement: a CTE inserts its event_log entry and
-- links every fact it records to that entry via audit_id (mirroring how
-- repository.record_facts works at runtime). occurred_at is back-dated so the
-- operations console reads as a believable founding-to-now timeline. Anchors are
-- id-only identity and carry no audit_id, so they are inserted up-front.
--
-- Demo beats (PRD §7): Marcus L4->L5 at 2026-07-01 (future-dated promotion); Aisha
-- annual leave 2026-06-08..22 (overlaps her live allocation); L5 rate 1200->1400 at
-- 2026-07-01 (rate-card change); Priya 0.5 + 0.5 fractional split.

-- Identity anchors (BY DEFAULT identity; explicit ids allowed) -----------------
INSERT INTO client (id) VALUES (1), (2), (3);
INSERT INTO engineer (id) VALUES (1), (2), (3);
INSERT INTO contract (id) VALUES (10), (20), (30);
INSERT INTO project (id) VALUES (100), (200), (300), (400), (500);

SELECT setval(pg_get_serial_sequence('client',   'id'), 3);
SELECT setval(pg_get_serial_sequence('engineer', 'id'), 3);
SELECT setval(pg_get_serial_sequence('contract', 'id'), 30);
SELECT setval(pg_get_serial_sequence('project',  'id'), 500);

-- Establish the rate card (what we CHARGE) — founding rows. --------------------
WITH e AS (
  INSERT INTO event_log (occurred_at, actor, operation, summary, payload) VALUES
    ('2024-01-01', 'seed', 'revise_rate_card', 'Establish rate card (L1-L7) from 2024-01-01',
     '{"levels":{"1":400,"2":600,"3":800,"4":1000,"5":1200,"6":1800,"7":2400},"effective":"2024-01-01"}')
  RETURNING id)
INSERT INTO rate_card (level, day_rate, effective_during, audit_id)
SELECT v.level, v.day_rate, v.eff, e.id FROM e,
  (VALUES (1, 400.00, daterange('2024-01-01','2027-01-01')),
          (2, 600.00, daterange('2024-01-01','2027-01-01')),
          (3, 800.00, daterange('2024-01-01','2027-01-01')),
          (4, 1000.00, daterange('2024-01-01','2027-01-01')),
          (5, 1200.00, daterange('2024-01-01','2026-07-01')),
          (6, 1800.00, daterange('2024-01-01','2027-01-01')),
          (7, 2400.00, daterange('2024-01-01','2027-01-01'))) AS v(level, day_rate, eff);

-- Set salaries (what we PAY) per level. ---------------------------------------
WITH e AS (
  INSERT INTO event_log (occurred_at, actor, operation, summary, payload) VALUES
    ('2024-01-01', 'seed', 'set_salary', 'Set salaries (L1-L7) from 2024-01-01',
     '{"levels":{"1":2000,"2":4000,"3":6000,"4":8000,"5":10000,"6":14000,"7":20000},"effective":"2024-01-01"}')
  RETURNING id)
INSERT INTO salary (level, monthly_salary, effective_during, audit_id)
SELECT v.level, v.monthly_salary, daterange('2024-01-01', NULL), e.id FROM e,
  (VALUES (1, 2000.00), (2, 4000.00), (3, 6000.00), (4, 8000.00), (5, 10000.00), (6, 14000.00), (7, 20000.00)) AS v(level, monthly_salary);

-- Set leave policy: annual 20 days/yr (L1-5) stepping to 25 for senior levels
-- (L6-7), sick 10 days/yr (all levels), from the company epoch. Per-level so a
-- promotion across L6 raises the annual accrual rate from the promotion date.
-- L1-5 annual is end-dated at 2025-07-01 below, where the policy is revised to 25.
WITH e AS (
  INSERT INTO event_log (occurred_at, actor, operation, summary, payload) VALUES
    ('2024-01-01', 'seed', 'set_leave_policy',
     'Set leave policy: annual 20/yr (L1-5), 25/yr (L6-7); sick 10/yr (all) from 2024-01-01',
     '{"annual":{"1-5":20,"6-7":25},"sick":{"all":10},"effective":"2024-01-01"}')
  RETURNING id)
INSERT INTO leave_policy (kind, level, days_per_year, effective_during, audit_id)
SELECT v.kind, v.level, v.days_per_year, v.eff, e.id FROM e,
  (VALUES
    ('annual', 1, 20.00, daterange('2024-01-01','2025-07-01')),
    ('annual', 2, 20.00, daterange('2024-01-01','2025-07-01')),
    ('annual', 3, 20.00, daterange('2024-01-01','2025-07-01')),
    ('annual', 4, 20.00, daterange('2024-01-01','2025-07-01')),
    ('annual', 5, 20.00, daterange('2024-01-01','2025-07-01')),
    ('annual', 6, 25.00, daterange('2024-01-01', NULL)),
    ('annual', 7, 25.00, daterange('2024-01-01', NULL)),
    ('sick', 1, 10.00, daterange('2024-01-01', NULL)),
    ('sick', 2, 10.00, daterange('2024-01-01', NULL)),
    ('sick', 3, 10.00, daterange('2024-01-01', NULL)),
    ('sick', 4, 10.00, daterange('2024-01-01', NULL)),
    ('sick', 5, 10.00, daterange('2024-01-01', NULL)),
    ('sick', 6, 10.00, daterange('2024-01-01', NULL)),
    ('sick', 7, 10.00, daterange('2024-01-01', NULL))
  ) AS v(kind, level, days_per_year, eff);

-- Revise the annual leave policy (L1-5) 20 -> 25 days/yr effective 2025-07-01: the
-- founding rows above end at the split date and these open [2025-07-01, ) at the
-- higher rate, so from 2025-07-01 every level accrues 25/yr (L6-7 were already 25).
-- The (kind, level) gist no-overlap constraint is satisfied because each band's two
-- spans abut without overlapping. This DOES lift Priya (L5) and Marcus (L4)
-- accrual; the over-balance leave refusal still holds — their balance stays well
-- under a four-month request (covered by the operations e2e).
WITH e AS (
  INSERT INTO event_log (occurred_at, actor, operation, summary, payload) VALUES
    ('2025-06-15', 'seed', 'set_leave_policy',
     'Revise leave policy: annual 25/yr (L1-5) from 2025-07-01',
     '{"annual":{"1-5":25},"effective":"2025-07-01"}')
  RETURNING id)
INSERT INTO leave_policy (kind, level, days_per_year, effective_during, audit_id)
SELECT v.kind, v.level, v.days_per_year, daterange('2025-07-01', NULL), e.id FROM e,
  (VALUES
    ('annual', 1, 25.00), ('annual', 2, 25.00), ('annual', 3, 25.00),
    ('annual', 4, 25.00), ('annual', 5, 25.00)
  ) AS v(kind, level, days_per_year);

-- Register clients. -----------------------------------------------------------
WITH e AS (
  INSERT INTO event_log (occurred_at, actor, operation, summary, payload) VALUES
    ('2024-01-01', 'seed', 'register_client', 'Register client Northwind Trading (client 1)',
     '{"client_id":1,"name":"Northwind Trading"}')
  RETURNING id)
INSERT INTO client_profile (client_id, name, recorded_during, audit_id)
SELECT 1, 'Northwind Trading', daterange('2024-01-01', NULL), e.id FROM e;

WITH e AS (
  INSERT INTO event_log (occurred_at, actor, operation, summary, payload) VALUES
    ('2025-01-01', 'seed', 'register_client', 'Register client Globex Corporation (client 2)',
     '{"client_id":2,"name":"Globex Corporation"}')
  RETURNING id)
INSERT INTO client_profile (client_id, name, recorded_during, audit_id)
SELECT 2, 'Globex Corporation', daterange('2024-01-01', NULL), e.id FROM e;

WITH e AS (
  INSERT INTO event_log (occurred_at, actor, operation, summary, payload) VALUES
    ('2026-05-01', 'seed', 'register_client', 'Register client Initech Systems (client 3)',
     '{"client_id":3,"name":"Initech Systems"}')
  RETURNING id)
INSERT INTO client_profile (client_id, name, recorded_during, audit_id)
SELECT 3, 'Initech Systems', daterange('2024-01-01', NULL), e.id FROM e;

-- Onboard engineers (employment, opening role, founding contact/banking/emergency).
WITH e AS (
  INSERT INTO event_log (occurred_at, actor, operation, summary, payload) VALUES
    ('2024-01-01', 'seed', 'onboard_engineer', 'Onboard Priya Sharma at L5 (engineer 1) from 2024-01-01',
     '{"name":"Priya Sharma","level":5,"effective":"2024-01-01"}')
  RETURNING id),
  emp AS (INSERT INTO employment (engineer_id, employed_during, audit_id)
          SELECT 1, daterange('2024-01-01','2027-01-01'), e.id FROM e),
  rol AS (INSERT INTO engineer_role (engineer_id, level, held_during, audit_id)
          SELECT 1, 5, daterange('2024-01-01','2027-01-01'), e.id FROM e),
  con AS (INSERT INTO engineer_contact (engineer_id, name, email, phone, postal_address, recorded_during, audit_id)
          SELECT 1, 'Priya Sharma', 'priya.sharma@alembic.com.au', '+61 400 000 001', '1 Demo St, Brisbane', daterange('2024-01-01', NULL), e.id FROM e),
  ban AS (INSERT INTO engineer_banking (engineer_id, bank, branch, account_no, account_name, recorded_during, audit_id)
          SELECT 1, 'Big Bank', '061', '00123451', 'Priya Sharma', daterange('2024-01-01', NULL), e.id FROM e)
INSERT INTO engineer_emergency (engineer_id, relation, name, phone, email, recorded_during, audit_id)
SELECT 1, 'spouse', 'Rohan Sharma', '+61 400 100 001', 'rohan.sharma@example.com', daterange('2024-01-01', NULL), e.id FROM e;

WITH e AS (
  INSERT INTO event_log (occurred_at, actor, operation, summary, payload) VALUES
    ('2024-06-01', 'seed', 'onboard_engineer', 'Onboard Marcus Chen at L4 (engineer 2) from 2024-06-01',
     '{"name":"Marcus Chen","level":4,"effective":"2024-06-01"}')
  RETURNING id),
  emp AS (INSERT INTO employment (engineer_id, employed_during, audit_id)
          SELECT 2, daterange('2024-06-01','2027-01-01'), e.id FROM e),
  rol AS (INSERT INTO engineer_role (engineer_id, level, held_during, audit_id)
          SELECT 2, 4, daterange('2024-06-01','2026-07-01'), e.id FROM e),
  con AS (INSERT INTO engineer_contact (engineer_id, name, email, phone, postal_address, recorded_during, audit_id)
          SELECT 2, 'Marcus Chen', 'marcus.chen@alembic.com.au', '+61 400 000 002', '2 Demo St, Brisbane', daterange('2024-01-01', NULL), e.id FROM e),
  ban AS (INSERT INTO engineer_banking (engineer_id, bank, branch, account_no, account_name, recorded_during, audit_id)
          SELECT 2, 'Big Bank', '062', '00123452', 'Marcus Chen', daterange('2024-01-01', NULL), e.id FROM e)
INSERT INTO engineer_emergency (engineer_id, relation, name, phone, email, recorded_during, audit_id)
SELECT 2, 'parent', 'Linda Chen', '+61 400 100 002', 'linda.chen@example.com', daterange('2024-01-01', NULL), e.id FROM e;

WITH e AS (
  INSERT INTO event_log (occurred_at, actor, operation, summary, payload) VALUES
    ('2025-01-01', 'seed', 'onboard_engineer', 'Onboard Aisha Okafor at L6 (engineer 3) from 2025-01-01',
     '{"name":"Aisha Okafor","level":6,"effective":"2025-01-01"}')
  RETURNING id),
  emp AS (INSERT INTO employment (engineer_id, employed_during, audit_id)
          SELECT 3, daterange('2025-01-01','2027-01-01'), e.id FROM e),
  rol AS (INSERT INTO engineer_role (engineer_id, level, held_during, audit_id)
          SELECT 3, 6, daterange('2025-01-01','2027-01-01'), e.id FROM e),
  con AS (INSERT INTO engineer_contact (engineer_id, name, email, phone, postal_address, recorded_during, audit_id)
          SELECT 3, 'Aisha Okafor', 'aisha.okafor@alembic.com.au', '+61 400 000 003', '3 Demo St, Brisbane', daterange('2024-01-01', NULL), e.id FROM e),
  ban AS (INSERT INTO engineer_banking (engineer_id, bank, branch, account_no, account_name, recorded_during, audit_id)
          SELECT 3, 'Big Bank', '063', '00123453', 'Aisha Okafor', daterange('2024-01-01', NULL), e.id FROM e)
INSERT INTO engineer_emergency (engineer_id, relation, name, phone, email, recorded_during, audit_id)
SELECT 3, 'sibling', 'Tunde Okafor', '+61 400 100 003', 'tunde.okafor@example.com', daterange('2024-01-01', NULL), e.id FROM e;

-- Sign contracts. -------------------------------------------------------------
WITH e AS (
  INSERT INTO event_log (occurred_at, actor, operation, summary, payload) VALUES
    ('2024-01-01', 'seed', 'sign_contract', 'Sign contract for Northwind Trading (contract 10) over 2024-01-01..2027-01-01',
     '{"client":"Northwind Trading","valid_from":"2024-01-01","valid_to":"2027-01-01"}')
  RETURNING id)
INSERT INTO contract_terms (contract_id, client_id, term, audit_id)
SELECT 10, 1, daterange('2024-01-01','2027-01-01'), e.id FROM e;

WITH e AS (
  INSERT INTO event_log (occurred_at, actor, operation, summary, payload) VALUES
    ('2025-01-01', 'seed', 'sign_contract', 'Sign contract for Globex Corporation (contract 20) over 2025-01-01..2027-01-01',
     '{"client":"Globex Corporation","valid_from":"2025-01-01","valid_to":"2027-01-01"}')
  RETURNING id)
INSERT INTO contract_terms (contract_id, client_id, term, audit_id)
SELECT 20, 2, daterange('2025-01-01','2027-01-01'), e.id FROM e;

-- Sign a forward contract for Initech Systems over the prospective window, so a
-- planned-but-unstaffed project can run under it (contract_terms PERIOD-FK contains
-- the project_run, which in turn contains the capacity requirements below).
WITH e AS (
  INSERT INTO event_log (occurred_at, actor, operation, summary, payload) VALUES
    ('2026-05-15', 'seed', 'sign_contract', 'Sign contract for Initech Systems (contract 30) over 2026-06-01..2027-01-01',
     '{"client":"Initech Systems","valid_from":"2026-06-01","valid_to":"2027-01-01"}')
  RETURNING id)
INSERT INTO contract_terms (contract_id, client_id, term, audit_id)
SELECT 30, 3, daterange('2026-06-01','2027-01-01'), e.id FROM e;

-- Start projects (run + founding profile + founding plan). --------------------
WITH e AS (
  INSERT INTO event_log (occurred_at, actor, operation, summary, payload) VALUES
    ('2024-01-01', 'seed', 'start_project', 'Start project Ledger Migration under contract 10 (project 100) over 2024-01-01..2027-01-01',
     '{"name":"Ledger Migration","contract_id":10,"valid_from":"2024-01-01","valid_to":"2027-01-01"}')
  RETURNING id),
  run AS (INSERT INTO project_run (project_id, contract_id, active_during, audit_id)
          SELECT 100, 10, daterange('2024-01-01','2027-01-01'), e.id FROM e),
  pro AS (INSERT INTO project_profile (project_id, title, summary, recorded_during, audit_id)
          SELECT 100, 'Ledger Migration', '', daterange('2024-01-01', NULL), e.id FROM e)
INSERT INTO project_plan (project_id, budget, target_completion, planned_during, audit_id)
SELECT 100, 500000.00, '2026-12-31', daterange('2024-01-01', NULL), e.id FROM e;

WITH e AS (
  INSERT INTO event_log (occurred_at, actor, operation, summary, payload) VALUES
    ('2025-06-01', 'seed', 'start_project', 'Start project Inventory Sync under contract 10 (project 200) over 2025-06-01..2027-01-01',
     '{"name":"Inventory Sync","contract_id":10,"valid_from":"2025-06-01","valid_to":"2027-01-01"}')
  RETURNING id),
  run AS (INSERT INTO project_run (project_id, contract_id, active_during, audit_id)
          SELECT 200, 10, daterange('2025-06-01','2027-01-01'), e.id FROM e),
  pro AS (INSERT INTO project_profile (project_id, title, summary, recorded_during, audit_id)
          SELECT 200, 'Inventory Sync', '', daterange('2024-01-01', NULL), e.id FROM e)
INSERT INTO project_plan (project_id, budget, target_completion, planned_during, audit_id)
SELECT 200, 300000.00, '2026-12-31', daterange('2025-06-01', NULL), e.id FROM e;

WITH e AS (
  INSERT INTO event_log (occurred_at, actor, operation, summary, payload) VALUES
    ('2025-01-01', 'seed', 'start_project', 'Start project Data Platform under contract 20 (project 300) over 2025-01-01..2027-01-01',
     '{"name":"Data Platform","contract_id":20,"valid_from":"2025-01-01","valid_to":"2027-01-01"}')
  RETURNING id),
  run AS (INSERT INTO project_run (project_id, contract_id, active_during, audit_id)
          SELECT 300, 20, daterange('2025-01-01','2027-01-01'), e.id FROM e),
  pro AS (INSERT INTO project_profile (project_id, title, summary, recorded_during, audit_id)
          SELECT 300, 'Data Platform', '', daterange('2024-01-01', NULL), e.id FROM e)
INSERT INTO project_plan (project_id, budget, target_completion, planned_during, audit_id)
SELECT 300, 800000.00, '2026-12-31', daterange('2025-01-01', NULL), e.id FROM e;

-- Start project Platform Telemetry but never staff it: an active run with ZERO
-- allocations, so the board's Unstaffed-projects lane shows it at the seed now.
-- Started 2026-02-01 (early 2026) so it demonstrates #19: before that date its
-- run has not started and it must be ABSENT from the projects list (not 'ended').
WITH e AS (
  INSERT INTO event_log (occurred_at, actor, operation, summary, payload) VALUES
    ('2026-02-01', 'seed', 'start_project', 'Start project Platform Telemetry under contract 20 (project 400) over 2026-02-01..2027-01-01',
     '{"name":"Platform Telemetry","contract_id":20,"valid_from":"2026-02-01","valid_to":"2027-01-01"}')
  RETURNING id),
  run AS (INSERT INTO project_run (project_id, contract_id, active_during, audit_id)
          SELECT 400, 20, daterange('2026-02-01','2027-01-01'), e.id FROM e),
  pro AS (INSERT INTO project_profile (project_id, title, summary, recorded_during, audit_id)
          SELECT 400, 'Platform Telemetry', '', daterange('2026-02-01', NULL), e.id FROM e)
INSERT INTO project_plan (project_id, budget, target_completion, planned_during, audit_id)
SELECT 400, 250000.00, '2026-12-31', daterange('2026-02-01', NULL), e.id FROM e;

-- Start a PROSPECTIVE project: Edge Analytics for Initech Systems. Its run is
-- active from 2026-06-01 (so at the seed now it surfaces in the board's
-- Unstaffed-projects lane alongside Platform Telemetry, the hiring signal), and it
-- carries capacity REQUIREMENTS (demand) over 2026-08-01..2027-01-01 but ZERO
-- allocations (supply). It is the demand-side seed beat: the forecast prices revenue
-- off its requirement lines despite no one being allocated (decision (b)). The
-- requirement window sits inside the run, which sits inside the contract term, so
-- both PERIOD-FKs hold.
WITH e AS (
  INSERT INTO event_log (occurred_at, actor, operation, summary, payload) VALUES
    ('2026-06-01', 'seed', 'start_project', 'Start project Edge Analytics under contract 30 (project 500) over 2026-06-01..2027-01-01',
     '{"name":"Edge Analytics","contract_id":30,"valid_from":"2026-06-01","valid_to":"2027-01-01"}')
  RETURNING id),
  run AS (INSERT INTO project_run (project_id, contract_id, active_during, audit_id)
          SELECT 500, 30, daterange('2026-06-01','2027-01-01'), e.id FROM e),
  pro AS (INSERT INTO project_profile (project_id, title, summary, recorded_during, audit_id)
          SELECT 500, 'Edge Analytics', '', daterange('2026-06-01', NULL), e.id FROM e)
INSERT INTO project_plan (project_id, budget, target_completion, planned_during, audit_id)
SELECT 500, 600000.00, '2026-12-31', daterange('2026-06-01', NULL), e.id FROM e;

-- Record Edge Analytics' capacity requirements (demand): 2× L3 + 1× L4 + 0.5× L5
-- over 2026-08-01..2027-01-01. No engineer fills them yet — the roles would be hired
-- — so the forecast prices them from the rate card / salary table directly.
WITH e AS (
  INSERT INTO event_log (occurred_at, actor, operation, summary, payload) VALUES
    ('2026-06-01', 'seed', 'set_project_requirement', 'Set Edge Analytics capacity: 2x L3 + 1x L4 + 0.5x L5 over 2026-08-01..2027-01-01',
     '{"project_id":500,"requirements":[{"level":3,"quantity":2},{"level":4,"quantity":1},{"level":5,"quantity":0.5}],"valid_from":"2026-08-01","valid_to":"2027-01-01"}')
  RETURNING id)
INSERT INTO project_requirement (project_id, level, quantity, required_during, audit_id)
SELECT 500, v.level, v.quantity, daterange('2026-08-01','2027-01-01'), e.id FROM e,
  (VALUES (3, 2.00), (4, 1.00), (5, 0.50)) AS v(level, quantity);

-- Assign engineers to projects (Priya is the 0.5 + 0.5 fractional split). ------
WITH e AS (
  INSERT INTO event_log (occurred_at, actor, operation, summary, payload) VALUES
    ('2024-01-01', 'seed', 'assign_to_project', 'Assign engineer 1 to project 100 at 0.5 over 2024-01-01..2027-01-01',
     '{"engineer_id":1,"project_id":100,"fraction":0.5,"valid_from":"2024-01-01","valid_to":"2027-01-01"}')
  RETURNING id)
INSERT INTO allocation (engineer_id, project_id, fraction, allocated_during, audit_id)
SELECT 1, 100, 0.50, daterange('2024-01-01','2027-01-01'), e.id FROM e;

WITH e AS (
  INSERT INTO event_log (occurred_at, actor, operation, summary, payload) VALUES
    ('2025-06-01', 'seed', 'assign_to_project', 'Assign engineer 1 to project 200 at 0.5 over 2025-06-01..2027-01-01',
     '{"engineer_id":1,"project_id":200,"fraction":0.5,"valid_from":"2025-06-01","valid_to":"2027-01-01"}')
  RETURNING id)
INSERT INTO allocation (engineer_id, project_id, fraction, allocated_during, audit_id)
SELECT 1, 200, 0.50, daterange('2025-06-01','2027-01-01'), e.id FROM e;

WITH e AS (
  INSERT INTO event_log (occurred_at, actor, operation, summary, payload) VALUES
    ('2025-01-01', 'seed', 'assign_to_project', 'Assign engineer 2 to project 300 at 1.0 over 2025-01-01..2027-01-01',
     '{"engineer_id":2,"project_id":300,"fraction":1.0,"valid_from":"2025-01-01","valid_to":"2027-01-01"}')
  RETURNING id)
INSERT INTO allocation (engineer_id, project_id, fraction, allocated_during, audit_id)
SELECT 2, 300, 1.00, daterange('2025-01-01','2027-01-01'), e.id FROM e;

WITH e AS (
  INSERT INTO event_log (occurred_at, actor, operation, summary, payload) VALUES
    ('2025-01-01', 'seed', 'assign_to_project', 'Assign engineer 3 to project 300 at 1.0 over 2025-01-01..2027-01-01',
     '{"engineer_id":3,"project_id":300,"fraction":1.0,"valid_from":"2025-01-01","valid_to":"2027-01-01"}')
  RETURNING id)
INSERT INTO allocation (engineer_id, project_id, fraction, allocated_during, audit_id)
SELECT 3, 300, 1.00, daterange('2025-01-01','2027-01-01'), e.id FROM e;

-- Promote Marcus L4 -> L5 at 2026-07-01 (the future-dated promotion). ----------
WITH e AS (
  INSERT INTO event_log (occurred_at, actor, operation, summary, payload) VALUES
    ('2026-06-01', 'seed', 'promote', 'Promote engineer 2 to L5 from 2026-07-01',
     '{"engineer_id":2,"level":5,"effective":"2026-07-01"}')
  RETURNING id)
INSERT INTO engineer_role (engineer_id, level, held_during, audit_id)
SELECT 2, 5, daterange('2026-07-01','2027-01-01'), e.id FROM e;

-- Revise the L5 day rate 1200 -> 1400 at 2026-07-01 (the rate-card change). -----
WITH e AS (
  INSERT INTO event_log (occurred_at, actor, operation, summary, payload) VALUES
    ('2026-06-01', 'seed', 'revise_rate_card', 'Revise L5 rate to 1400 from 2026-07-01',
     '{"level":5,"day_rate":1400,"effective":"2026-07-01"}')
  RETURNING id)
INSERT INTO rate_card (level, day_rate, effective_during, audit_id)
SELECT 5, 1400.00, daterange('2026-07-01','2027-01-01'), e.id FROM e;

-- Aisha takes annual leave across the seed "now". -----------------------------
WITH e AS (
  INSERT INTO event_log (occurred_at, actor, operation, summary, payload) VALUES
    ('2026-06-01', 'seed', 'take_leave', 'Engineer 3 on annual leave over 2026-06-08..2026-06-22',
     '{"engineer_id":3,"kind":"annual","valid_from":"2026-06-08","valid_to":"2026-06-22"}')
  RETURNING id)
INSERT INTO leave (engineer_id, kind, on_leave_during, audit_id)
SELECT 3, 'annual', daterange('2026-06-08','2026-06-22'), e.id FROM e;

-- Priya logs Tue 2026-06-09 against both her half-time projects. ---------------
WITH e AS (
  INSERT INTO event_log (occurred_at, actor, operation, summary, payload) VALUES
    ('2026-06-09', 'seed', 'log_timesheet', 'Log 4h for engineer 1 on project 100 on 2026-06-09',
     '{"engineer_id":1,"project_id":100,"day":"2026-06-09","hours":4}')
  RETURNING id)
INSERT INTO timesheet (engineer_id, project_id, work_day, hours, audit_id)
SELECT 1, 100, daterange('2026-06-09','2026-06-10'), 4.00, e.id FROM e;

WITH e AS (
  INSERT INTO event_log (occurred_at, actor, operation, summary, payload) VALUES
    ('2026-06-09', 'seed', 'log_timesheet', 'Log 4h for engineer 1 on project 200 on 2026-06-09',
     '{"engineer_id":1,"project_id":200,"day":"2026-06-09","hours":4}')
  RETURNING id)
INSERT INTO timesheet (engineer_id, project_id, work_day, hours, audit_id)
SELECT 1, 200, daterange('2026-06-09','2026-06-10'), 4.00, e.id FROM e;
