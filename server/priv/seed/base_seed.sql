-- base_seed.sql — the deterministic demo seed, with realistic provenance.
--
-- NOT an auto-applied migration. It lives outside priv/migrations so the forward
-- runner can never inject this fictional cast into a real environment; it is applied
-- only by the dev-only `tempo/seed` entrypoint (`bin/seed`), which refuses to run
-- unless TEMPO_ENV is dev and the DB is empty. (Formerly the unconditionally-applied
-- 002_seed.sql migration.)
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
-- 2026-07-01 (rate-card change); Priya 0.5 + 0.5 fractional split. Capability/skill
-- taxonomy (4 capabilities, 12 skills): Priya assessed strong on Payments Platform,
-- Marcus growing into Data Engineering (with a mid-2026 reassessment bump), Aisha
-- broad across Data Engineering and Platform Infrastructure but light on Payments.

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

-- Capability & skill taxonomy (#38): 4 capabilities over 12 skills, so the three
-- engineers show an interesting, non-uniform proficiency picture — Priya strong on
-- Payments, Marcus growing into Data Engineering, Aisha broad across Data/Platform
-- Infrastructure with a Payments gap. ---------------------------------------------
INSERT INTO capability (id) VALUES (1), (2), (3), (4);
INSERT INTO skill (id) VALUES (1), (2), (3), (4), (5), (6), (7), (8), (9), (10), (11), (12);

SELECT setval(pg_get_serial_sequence('capability', 'id'), 4);
SELECT setval(pg_get_serial_sequence('skill',       'id'), 12);

WITH e AS (
  INSERT INTO event_log (occurred_at, actor, operation, summary, payload) VALUES
    ('2026-01-05', 'seed', 'define_capability', 'Define capability taxonomy: Payments Platform, Data Engineering, Frontend Delivery, Platform Infrastructure',
     '{"capabilities":[{"id":1,"name":"Payments Platform"},{"id":2,"name":"Data Engineering"},{"id":3,"name":"Frontend Delivery"},{"id":4,"name":"Platform Infrastructure"}],"effective":"2026-01-05"}')
  RETURNING id)
INSERT INTO capability_profile (capability_id, name, summary, defined_during, audit_id)
SELECT v.capability_id, v.name, v.summary, daterange('2026-01-05', NULL, '[)'), e.id FROM e,
  (VALUES
    (1, 'Payments Platform', 'Billing, ledger, and payment-gateway integrations'),
    (2, 'Data Engineering', 'Pipelines, warehousing, and distributed data systems'),
    (3, 'Frontend Delivery', 'Client applications and the interfaces engineers ship them through'),
    (4, 'Platform Infrastructure', 'Cloud infrastructure, deployment, and operability')
  ) AS v(capability_id, name, summary);

WITH e AS (
  INSERT INTO event_log (occurred_at, actor, operation, summary, payload) VALUES
    ('2026-01-05', 'seed', 'define_skill', 'Define skill taxonomy: 12 skills across payments, data, frontend, and platform infrastructure',
     '{"skills":[{"id":1,"name":"Payment Gateways"},{"id":2,"name":"PCI Compliance"},{"id":3,"name":"Ledger Accounting Systems"},{"id":4,"name":"API Design"},{"id":5,"name":"SQL & Database Design"},{"id":6,"name":"Data Pipelines"},{"id":7,"name":"Distributed Systems"},{"id":8,"name":"Frontend Development"},{"id":9,"name":"UI/UX Design"},{"id":10,"name":"Kubernetes"},{"id":11,"name":"CI/CD"},{"id":12,"name":"Cloud Infrastructure"}],"effective":"2026-01-05"}')
  RETURNING id)
INSERT INTO skill_profile (skill_id, name, summary, defined_during, audit_id)
SELECT v.skill_id, v.name, v.summary, daterange('2026-01-05', NULL, '[)'), e.id FROM e,
  (VALUES
    (1, 'Payment Gateways', 'Integrating and operating third-party payment gateways'),
    (2, 'PCI Compliance', 'Handling cardholder data within PCI-DSS controls'),
    (3, 'Ledger Accounting Systems', 'Double-entry ledgers and reconciliation'),
    (4, 'API Design', 'Designing stable, versioned service interfaces'),
    (5, 'SQL & Database Design', 'Relational schema design and query optimisation'),
    (6, 'Data Pipelines', 'Building and operating ETL/ELT pipelines'),
    (7, 'Distributed Systems', 'Consistency, partitioning, and failure handling at scale'),
    (8, 'Frontend Development', 'Building client applications'),
    (9, 'UI/UX Design', 'Interaction and visual design for user-facing products'),
    (10, 'Kubernetes', 'Operating containerised workloads on Kubernetes'),
    (11, 'CI/CD', 'Build, test, and deployment pipelines'),
    (12, 'Cloud Infrastructure', 'Provisioning and operating cloud infrastructure')
  ) AS v(skill_id, name, summary);

-- Compose each capability from its weighted skills (weight 1-3: how much that
-- skill counts toward the capability's rollup). ------------------------------
WITH e AS (
  INSERT INTO event_log (occurred_at, actor, operation, summary, payload) VALUES
    ('2026-01-06', 'seed', 'set_capability_skill', 'Compose Payments Platform from Payment Gateways(3), PCI Compliance(3), Ledger Accounting Systems(2), API Design(1)',
     '{"capability_id":1,"weights":{"1":3,"2":3,"3":2,"4":1},"effective":"2026-01-06"}')
  RETURNING id)
INSERT INTO capability_skill (capability_id, skill_id, weight, mapped_during, audit_id)
SELECT 1, v.skill_id, v.weight, daterange('2026-01-06', NULL, '[)'), e.id
FROM e, (VALUES (1, 3), (2, 3), (3, 2), (4, 1)) AS v(skill_id, weight);

WITH e AS (
  INSERT INTO event_log (occurred_at, actor, operation, summary, payload) VALUES
    ('2026-01-06', 'seed', 'set_capability_skill', 'Compose Data Engineering from SQL & Database Design(3), Data Pipelines(3), Distributed Systems(2)',
     '{"capability_id":2,"weights":{"5":3,"6":3,"7":2},"effective":"2026-01-06"}')
  RETURNING id)
INSERT INTO capability_skill (capability_id, skill_id, weight, mapped_during, audit_id)
SELECT 2, v.skill_id, v.weight, daterange('2026-01-06', NULL, '[)'), e.id
FROM e, (VALUES (5, 3), (6, 3), (7, 2)) AS v(skill_id, weight);

WITH e AS (
  INSERT INTO event_log (occurred_at, actor, operation, summary, payload) VALUES
    ('2026-01-06', 'seed', 'set_capability_skill', 'Compose Frontend Delivery from Frontend Development(3), UI/UX Design(2), API Design(1)',
     '{"capability_id":3,"weights":{"8":3,"9":2,"4":1},"effective":"2026-01-06"}')
  RETURNING id)
INSERT INTO capability_skill (capability_id, skill_id, weight, mapped_during, audit_id)
SELECT 3, v.skill_id, v.weight, daterange('2026-01-06', NULL, '[)'), e.id
FROM e, (VALUES (8, 3), (9, 2), (4, 1)) AS v(skill_id, weight);

WITH e AS (
  INSERT INTO event_log (occurred_at, actor, operation, summary, payload) VALUES
    ('2026-01-06', 'seed', 'set_capability_skill', 'Compose Platform Infrastructure from Kubernetes(3), CI/CD(2), Cloud Infrastructure(3), Distributed Systems(1)',
     '{"capability_id":4,"weights":{"10":3,"11":2,"12":3,"7":1}}')
  RETURNING id)
INSERT INTO capability_skill (capability_id, skill_id, weight, mapped_during, audit_id)
SELECT 4, v.skill_id, v.weight, daterange('2026-01-06', NULL, '[)'), e.id
FROM e, (VALUES (10, 3), (11, 2), (12, 3), (7, 1)) AS v(skill_id, weight);

-- Assess the three engineers against the skill catalog. Ranges are bounded to
-- each engineer's employment upper (2027-01-01) to satisfy the PERIOD FK — open-
-- ended uppers would violate engineer_skill_within_employment. -----------------
WITH e AS (
  INSERT INTO event_log (occurred_at, actor, operation, summary, payload) VALUES
    ('2026-01-12', 'seed', 'assess_skill', 'Assess engineer 1 (Priya): strong across Payments, developing on Data',
     '{"engineer_id":1,"levels":{"1":4,"2":3,"3":4,"4":3,"5":2,"8":2},"effective":"2026-01-12"}')
  RETURNING id)
INSERT INTO engineer_skill (engineer_id, skill_id, level, assessed_during, audit_id)
SELECT 1, v.skill_id, v.level, daterange('2026-01-12', '2027-01-01', '[)'), e.id
FROM e, (VALUES (1, 4), (2, 3), (3, 4), (4, 3), (5, 2), (8, 2)) AS v(skill_id, level);

WITH e AS (
  INSERT INTO event_log (occurred_at, actor, operation, summary, payload) VALUES
    ('2026-01-12', 'seed', 'assess_skill', 'Assess engineer 2 (Marcus): growing into Data Engineering',
     '{"engineer_id":2,"levels":{"5":4,"6":3,"7":3,"4":2,"11":2,"12":2},"effective":"2026-01-12"}')
  RETURNING id)
INSERT INTO engineer_skill (engineer_id, skill_id, level, assessed_during, audit_id)
SELECT 2, v.skill_id, v.level, daterange('2026-01-12', v.valid_to, '[)'), e.id
FROM e, (VALUES (5, 4, '2027-01-01'::date), (6, 3, '2026-05-01'::date), (7, 3, '2027-01-01'::date), (4, 2, '2027-01-01'::date), (11, 2, '2027-01-01'::date), (12, 2, '2027-01-01'::date)) AS v(skill_id, level, valid_to);

WITH e AS (
  INSERT INTO event_log (occurred_at, actor, operation, summary, payload) VALUES
    ('2026-01-12', 'seed', 'assess_skill', 'Assess engineer 3 (Aisha): broad senior coverage across Data and Platform Infrastructure, light on Payments',
     '{"engineer_id":3,"levels":{"7":4,"10":4,"11":3,"12":4,"6":3,"5":3,"1":1},"effective":"2026-01-12"}')
  RETURNING id)
INSERT INTO engineer_skill (engineer_id, skill_id, level, assessed_during, audit_id)
SELECT 3, v.skill_id, v.level, daterange('2026-01-12', '2027-01-01', '[)'), e.id
FROM e, (VALUES (7, 4), (10, 4), (11, 3), (12, 4), (6, 3), (5, 3), (1, 1)) AS v(skill_id, level);

-- Re-assess Marcus on Data Pipelines from 2026-05-01: 3 -> 4, closing his first
-- assessed span and opening a new one to the employment upper (the same
-- delete-then-insert shape the runtime upsert applies, written out by hand). ----
WITH e AS (
  INSERT INTO event_log (occurred_at, actor, operation, summary, payload) VALUES
    ('2026-05-01', 'seed', 'assess_skill', 'Reassess engineer 2 (Marcus) on Data Pipelines: 3 -> 4 from 2026-05-01',
     '{"engineer_id":2,"skill_id":6,"level":4,"effective":"2026-05-01"}')
  RETURNING id)
INSERT INTO engineer_skill (engineer_id, skill_id, level, assessed_during, audit_id)
SELECT 2, 6, 4, daterange('2026-05-01', '2027-01-01', '[)'), e.id FROM e;

-- Record Ledger Migration's capability demand (#39): Payments Platform target L3
-- x2.00. Priya, the only engineer allocated to project 100, rolls up to ~3.56 on
-- Payments Platform (Payment Gateways(3)=4, PCI Compliance(3)=3, Ledger Accounting
-- Systems(2)=4, API Design(1)=3 -> 32/9), so she covers the requirement alone --
-- one engineer against a quantity of two, a visible gap of one. -----------------
WITH e AS (
  INSERT INTO event_log (occurred_at, actor, operation, summary, payload) VALUES
    ('2026-01-10', 'seed', 'set_project_capability', 'Set Ledger Migration capability: Payments Platform target L3 x2.00 over 2026-01-10..2027-01-01',
     '{"project_id":100,"capability_id":1,"target_level":3,"quantity":2.00,"valid_from":"2026-01-10","valid_to":"2027-01-01"}')
  RETURNING id)
INSERT INTO project_capability (project_id, capability_id, target_level, quantity, required_during, audit_id)
SELECT 100, 1, 3, 2.00, daterange('2026-01-10','2027-01-01'), e.id FROM e;

-- Record a second Ledger Migration capability demand for contrast: Frontend
-- Delivery target L1 x1.00. Priya rolls up to 1.5 on Frontend Delivery (Frontend
-- Development(3)=2, UI/UX Design(2)=0, API Design(1)=3 -> 9/6), clearing the
-- target -- fully covered against the required quantity of one. ----------------
WITH e AS (
  INSERT INTO event_log (occurred_at, actor, operation, summary, payload) VALUES
    ('2026-01-10', 'seed', 'set_project_capability', 'Set Ledger Migration capability: Frontend Delivery target L1 x1.00 over 2026-01-10..2027-01-01',
     '{"project_id":100,"capability_id":3,"target_level":1,"quantity":1.00,"valid_from":"2026-01-10","valid_to":"2027-01-01"}')
  RETURNING id)
INSERT INTO project_capability (project_id, capability_id, target_level, quantity, required_during, audit_id)
SELECT 100, 3, 1, 1.00, daterange('2026-01-10','2027-01-01'), e.id FROM e;

-- Seed engineer locations (scheduling Phase A): Marcus in the US open-ended; Priya
-- relocates from Sydney to London on 2026-07-01, so as-of reads either side of that
-- date resolve a different TZID; Aisha in London throughout. ---------------------
WITH e AS (
  INSERT INTO event_log (occurred_at, actor, operation, summary, payload) VALUES
    ('2024-03-01', 'seed', 'set_engineer_location', 'Set location of engineer 2 (Marcus) to America/Los_Angeles (US) from 2024-03-01',
     '{"engineer_id":2,"country":"US","region":"US-CA","timezone":"America/Los_Angeles","effective":"2024-03-01"}')
  RETURNING id)
INSERT INTO engineer_location (engineer_id, located_during, country, region, timezone, audit_id)
SELECT 2, daterange('2024-03-01', NULL, '[)'), 'US', 'US-CA', 'America/Los_Angeles', e.id FROM e;

WITH e AS (
  INSERT INTO event_log (occurred_at, actor, operation, summary, payload) VALUES
    ('2024-03-01', 'seed', 'set_engineer_location', 'Set location of engineer 1 (Priya) to Australia/Sydney (AU) from 2024-03-01',
     '{"engineer_id":1,"country":"AU","region":"AU-NSW","timezone":"Australia/Sydney","effective":"2024-03-01"}')
  RETURNING id)
INSERT INTO engineer_location (engineer_id, located_during, country, region, timezone, audit_id)
SELECT 1, daterange('2024-03-01', '2026-07-01', '[)'), 'AU', 'AU-NSW', 'Australia/Sydney', e.id FROM e;

WITH e AS (
  INSERT INTO event_log (occurred_at, actor, operation, summary, payload) VALUES
    ('2026-07-01', 'seed', 'set_engineer_location', 'Relocate engineer 1 (Priya) to Europe/London (GB) from 2026-07-01',
     '{"engineer_id":1,"country":"GB","region":"GB-LND","timezone":"Europe/London","effective":"2026-07-01"}')
  RETURNING id)
INSERT INTO engineer_location (engineer_id, located_during, country, region, timezone, audit_id)
SELECT 1, daterange('2026-07-01', NULL, '[)'), 'GB', 'GB-LND', 'Europe/London', e.id FROM e;

WITH e AS (
  INSERT INTO event_log (occurred_at, actor, operation, summary, payload) VALUES
    ('2023-09-12', 'seed', 'set_engineer_location', 'Set location of engineer 3 (Aisha) to Europe/London (GB) from 2023-09-12',
     '{"engineer_id":3,"country":"GB","region":"GB-LND","timezone":"Europe/London","effective":"2023-09-12"}')
  RETURNING id)
INSERT INTO engineer_location (engineer_id, located_during, country, region, timezone, audit_id)
SELECT 3, daterange('2023-09-12', NULL, '[)'), 'GB', 'GB-LND', 'Europe/London', e.id FROM e;

-- Seed meetings (scheduling Phase C): a July all-hands spanning three zones, and a
-- June client sync, both after seed-now (2026-06-15) so the upcoming read returns them.
WITH e AS (
  INSERT INTO event_log (occurred_at, actor, operation, summary, payload) VALUES
    ('2026-06-01', 'seed', 'schedule_meeting',
     'Scheduled "July all-hands" on 2026-07-10 09:00 (Europe/London)',
     '{"title":"July all-hands","timezone":"Europe/London","date":"2026-07-10","starts_at":"09:00","duration_minutes":60,"location":null,"client_id":null,"project_id":null,"attendees":[{"engineer_id":1,"attendance":"required"},{"engineer_id":2,"attendance":"optional"},{"engineer_id":3,"attendance":"required"}]}')
  RETURNING id),
m AS (INSERT INTO meeting DEFAULT VALUES RETURNING id),
s AS (
  INSERT INTO meeting_subject (meeting_id, title, client_id, project_id, audit_id)
  SELECT m.id, 'July all-hands', NULL, NULL, e.id
  FROM m, e RETURNING meeting_id),
d AS (
  INSERT INTO meeting_booking (meeting_id, occupies, meeting_tz, location, booked_during, audit_id)
  SELECT s.meeting_id,
    tstzrange(('2026-07-10 09:00'::timestamp AT TIME ZONE 'Europe/London'),
              ('2026-07-10 09:00'::timestamp AT TIME ZONE 'Europe/London') + interval '60 minutes', '[)'),
    'Europe/London', NULL,
    tstzrange('2026-06-01'::timestamptz, NULL, '[)'),
    e.id
  FROM s, e RETURNING meeting_id)
INSERT INTO meeting_attendee (meeting_id, engineer_id, attendance)
SELECT d.meeting_id, v.engineer_id, v.attendance
FROM d, (VALUES (1, 'required'), (2, 'optional'), (3, 'required')) AS v(engineer_id, attendance);

WITH e AS (
  INSERT INTO event_log (occurred_at, actor, operation, summary, payload) VALUES
    ('2026-06-01', 'seed', 'schedule_meeting',
     'Scheduled "LA client sync" on 2026-06-20 14:00 (America/Los_Angeles)',
     '{"title":"LA client sync","timezone":"America/Los_Angeles","date":"2026-06-20","starts_at":"14:00","duration_minutes":30,"location":null,"client_id":null,"project_id":null,"attendees":[{"engineer_id":2,"attendance":"required"}]}')
  RETURNING id),
m AS (INSERT INTO meeting DEFAULT VALUES RETURNING id),
s AS (
  INSERT INTO meeting_subject (meeting_id, title, client_id, project_id, audit_id)
  SELECT m.id, 'LA client sync', NULL, NULL, e.id
  FROM m, e RETURNING meeting_id),
d AS (
  INSERT INTO meeting_booking (meeting_id, occupies, meeting_tz, location, booked_during, audit_id)
  SELECT s.meeting_id,
    tstzrange(('2026-06-20 14:00'::timestamp AT TIME ZONE 'America/Los_Angeles'),
              ('2026-06-20 14:00'::timestamp AT TIME ZONE 'America/Los_Angeles') + interval '30 minutes', '[)'),
    'America/Los_Angeles', NULL,
    tstzrange('2026-06-01'::timestamptz, NULL, '[)'),
    e.id
  FROM s, e RETURNING meeting_id)
INSERT INTO meeting_attendee (meeting_id, engineer_id, attendance)
SELECT d.meeting_id, v.engineer_id, v.attendance
FROM d, (VALUES (2, 'required')) AS v(engineer_id, attendance);

-- Seed availability (scheduling Phase B): default 9-17 Mon-Fri for all engineers,
-- Priya drops Fridays from 2026-07-01, one Marcus focus block, and 2026 holidays
-- for the three seeded regions.
WITH e AS (
  INSERT INTO event_log (occurred_at, actor, operation, summary, payload) VALUES
    ('2024-01-01', 'seed', 'set_work_schedule', 'Seed default 9-17 Mon-Fri for engineers 1-3', '{}')
  RETURNING id)
INSERT INTO work_schedule (engineer_id, weekday, valid_at, starts, ends, audit_id)
SELECT eng.engineer_id, wd.weekday, daterange('2024-01-01', NULL, '[)'), '09:00'::time, '17:00'::time, e.id
FROM e,
     (VALUES (1), (2), (3)) AS eng(engineer_id),
     (VALUES (0), (1), (2), (3), (4)) AS wd(weekday);

INSERT INTO event_log (occurred_at, actor, operation, summary, payload) VALUES
  ('2026-06-20', 'seed', 'set_work_schedule', 'Priya drops Fridays from 2026-07-01', '{}');
DELETE FROM work_schedule
   FOR PORTION OF valid_at FROM '2026-07-01' TO NULL
 WHERE engineer_id = 1 AND weekday = 4;

WITH e AS (
  INSERT INTO event_log (occurred_at, actor, operation, summary, payload) VALUES
    ('2026-06-10', 'seed', 'add_focus_block', 'Added focus block "Deep work: incident review" for engineer 2 on 2026-06-22', '{}')
  RETURNING id)
INSERT INTO focus_block (engineer_id, busy_at, title, audit_id)
SELECT 2,
  tstzrange(('2026-06-22 13:00'::timestamp AT TIME ZONE 'America/Los_Angeles'),
            ('2026-06-22 13:00'::timestamp AT TIME ZONE 'America/Los_Angeles') + interval '120 minutes', '[)'),
  'Deep work: incident review', e.id
FROM e;

WITH e AS (
  INSERT INTO event_log (occurred_at, actor, operation, summary, payload) VALUES
    ('2026-01-05', 'seed', 'import_holidays', 'Imported 5 public holidays for AU/US/GB 2026', '{}')
  RETURNING id)
INSERT INTO holiday (country, region, holiday_on, name, audit_id)
SELECT v.country, v.region, v.holiday_on::date, v.name, e.id
FROM e, (VALUES
  ('AU', '', '2026-12-25', 'Christmas Day'),
  ('AU', 'AU-NSW', '2026-10-05', 'Labour Day'),
  ('US', '', '2026-11-26', 'Thanksgiving'),
  ('US', 'US-CA', '2026-09-09', 'California Admission Day'),
  ('GB', '', '2026-08-31', 'Summer Bank Holiday')
) AS v(country, region, holiday_on, name);
