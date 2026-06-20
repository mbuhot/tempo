-- 002_seed.sql — the deterministic demo seed (squash of the original 003 + the
-- founding-fact backfills 012/014/015/016).
--
-- Hand-written: explicit ids, names, dates, rates — no factory sequences. Consumed
-- unchanged by the as-of query tests and the Playwright suite, so it must stay stable.
--
-- Fixed seed "now" = 2026-06-15. The UI slider and every test anchor to this date,
-- not the system clock.
--
-- Demo beats (PRD §7) all have their data:
--   * future-dated promotion ...... Marcus Chen: L4 -> L5 at 2026-07-01 (after now)
--   * leave overlapping allocation . Aisha Okafor: annual 2026-06-08..2026-06-22
--   * rate-card change ............. L5 day_rate 1200 -> 1400 at 2026-07-01
--   * fractional split ............. Priya Sharma: 0.5 on project 100 AND 0.5 on 200
--
-- Allocations are whole-engagement rows: the cost layer derives the charge rate live
-- from rate_card x engineer_role, so there is no cached day_rate to fragment.

-- Identity anchors (BY DEFAULT identity, so explicit ids are allowed) ----------
INSERT INTO client (id) VALUES (1), (2);
INSERT INTO engineer (id) VALUES (1), (2), (3);
INSERT INTO contract (id) VALUES (10), (20);
INSERT INTO project (id) VALUES (100), (200), (300);

-- Keep each anchor's id sequence ahead of the pinned ids so future app-driven
-- inserts (reserved via nextval) do not collide.
SELECT setval(pg_get_serial_sequence('client',   'id'), 2);
SELECT setval(pg_get_serial_sequence('engineer', 'id'), 3);
SELECT setval(pg_get_serial_sequence('contract', 'id'), 20);
SELECT setval(pg_get_serial_sequence('project',  'id'), 300);

-- Client / engineer profiles (latest-read facts off the anchors) --------------
INSERT INTO client_profile (client_id, name, recorded_during) VALUES
  (1, 'Northwind Trading',  daterange('2024-01-01', NULL)),
  (2, 'Globex Corporation', daterange('2024-01-01', NULL));

INSERT INTO engineer_contact (engineer_id, name, email, phone, postal_address, recorded_during) VALUES
  (1, 'Priya Sharma',  'priya.sharma@alembic.com.au',  '+61 400 000 001', '1 Demo St, Brisbane', daterange('2024-01-01', NULL)),
  (2, 'Marcus Chen',   'marcus.chen@alembic.com.au',   '+61 400 000 002', '2 Demo St, Brisbane', daterange('2024-01-01', NULL)),
  (3, 'Aisha Okafor',  'aisha.okafor@alembic.com.au',  '+61 400 000 003', '3 Demo St, Brisbane', daterange('2024-01-01', NULL));

INSERT INTO engineer_banking (engineer_id, bank, branch, account_no, account_name, recorded_during) VALUES
  (1, 'Big Bank', '061', '00123451', 'Priya Sharma', daterange('2024-01-01', NULL)),
  (2, 'Big Bank', '062', '00123452', 'Marcus Chen',  daterange('2024-01-01', NULL)),
  (3, 'Big Bank', '063', '00123453', 'Aisha Okafor', daterange('2024-01-01', NULL));

INSERT INTO engineer_emergency (engineer_id, relation, name, phone, email, recorded_during) VALUES
  (1, 'spouse',  'Rohan Sharma', '+61 400 100 001', 'rohan.sharma@example.com', daterange('2024-01-01', NULL)),
  (2, 'parent',  'Linda Chen',   '+61 400 100 002', 'linda.chen@example.com',   daterange('2024-01-01', NULL)),
  (3, 'sibling', 'Tunde Okafor', '+61 400 100 003', 'tunde.okafor@example.com', daterange('2024-01-01', NULL));

-- Rate card (what we CHARGE). L5 steps up mid-2026 (the rate-card-change beat). --
INSERT INTO rate_card (level, day_rate, effective_during) VALUES
  (3,  800.00, daterange('2024-01-01', '2027-01-01')),
  (4, 1000.00, daterange('2024-01-01', '2027-01-01')),
  (5, 1200.00, daterange('2024-01-01', '2026-07-01')),
  (5, 1400.00, daterange('2026-07-01', '2027-01-01')),
  (6, 1800.00, daterange('2024-01-01', '2027-01-01'));

-- Salary (what we PAY), per level, open-ended. --------------------------------
INSERT INTO salary (level, monthly_salary, effective_during) VALUES
  (3,  6000.00, daterange('2024-01-01', NULL)),
  (4,  8000.00, daterange('2024-01-01', NULL)),
  (5, 10000.00, daterange('2024-01-01', NULL)),
  (6, 14000.00, daterange('2024-01-01', NULL));

-- Engagements: contract terms, then the project runs contained by them. -------
INSERT INTO contract_terms (contract_id, client_id, term) VALUES
  (10, 1, daterange('2024-01-01', '2027-01-01')),   -- Northwind
  (20, 2, daterange('2025-01-01', '2027-01-01'));    -- Globex

INSERT INTO project_run (project_id, contract_id, active_during) VALUES
  (100, 10, daterange('2024-01-01', '2027-01-01')),  -- Ledger Migration
  (200, 10, daterange('2025-06-01', '2027-01-01')),  -- Inventory Sync
  (300, 20, daterange('2025-01-01', '2027-01-01'));   -- Data Platform

INSERT INTO project_profile (project_id, title, summary, recorded_during) VALUES
  (100, 'Ledger Migration', '', daterange('2024-01-01', NULL)),
  (200, 'Inventory Sync',   '', daterange('2024-01-01', NULL)),
  (300, 'Data Platform',    '', daterange('2024-01-01', NULL));

INSERT INTO project_plan (project_id, budget, target_completion, planned_during) VALUES
  (100, 500000.00, '2026-12-31', daterange('2024-01-01', NULL)),
  (200, 300000.00, '2026-12-31', daterange('2025-06-01', NULL)),
  (300, 800000.00, '2026-12-31', daterange('2025-01-01', NULL));

-- Employment: root of the containment chain. ----------------------------------
INSERT INTO employment (engineer_id, employed_during) VALUES
  (1, daterange('2024-01-01', '2027-01-01')),   -- Priya
  (2, daterange('2024-06-01', '2027-01-01')),   -- Marcus
  (3, daterange('2025-01-01', '2027-01-01'));    -- Aisha

-- Roles. Marcus's L4 -> L5 at 2026-07-01 is the future-dated promotion. --------
INSERT INTO engineer_role (engineer_id, level, held_during) VALUES
  (1, 5, daterange('2024-01-01', '2027-01-01')),  -- Priya: L5 throughout
  (2, 4, daterange('2024-06-01', '2026-07-01')),  -- Marcus: L4 before promotion
  (2, 5, daterange('2026-07-01', '2027-01-01')),  -- Marcus: L5 after promotion
  (3, 6, daterange('2025-01-01', '2027-01-01'));   -- Aisha: L6 throughout

-- Allocations (whole-engagement). Priya is the 0.5 + 0.5 fractional split. -----
INSERT INTO allocation (engineer_id, project_id, fraction, allocated_during) VALUES
  (1, 100, 0.50, daterange('2024-01-01', '2027-01-01')),
  (1, 200, 0.50, daterange('2025-06-01', '2027-01-01')),
  (2, 300, 1.00, daterange('2025-01-01', '2027-01-01')),
  (3, 300, 1.00, daterange('2025-01-01', '2027-01-01'));

-- Leave: Aisha on annual leave across the seed "now", overlapping her project. -
INSERT INTO leave (engineer_id, kind, on_leave_during) VALUES
  (3, 'annual', daterange('2026-06-08', '2026-06-22'));

-- Timesheet: Priya logged Tue 2026-06-09 against both her half-time projects. --
INSERT INTO timesheet (engineer_id, project_id, work_day, hours) VALUES
  (1, 100, daterange('2026-06-09', '2026-06-10'), 4.00),
  (1, 200, daterange('2026-06-09', '2026-06-10'), 4.00);
