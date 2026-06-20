-- 018_id_sequences.sql — give every command-minted anchor an explicit, app-driven
-- id sequence. This replaces GENERATED ALWAYS AS IDENTITY (engineer/invoice/
-- payroll_run) and the race-prone coalesce(max(id),0)+1 mint (contract/project).
-- A handler now reads the next id with nextval BEFORE inserting, so it threads the
-- id into every fact it records without reading anything back (no RETURNING).
--
-- Each sequence is OWNED BY its column (dropped with the table) and seeded past the
-- current max: setval to GREATEST(max,1) with is_called = (max > 0), so a populated
-- anchor continues at max+1 and an empty one (invoice/payroll_run at migrate time,
-- before the financial seed runs) starts at 1.

-- engineer / invoice / payroll_run were GENERATED ALWAYS AS IDENTITY: drop the
-- identity, own a plain sequence, default it onto the column.
ALTER TABLE engineer ALTER COLUMN id DROP IDENTITY IF EXISTS;
CREATE SEQUENCE engineer_id_seq OWNED BY engineer.id;
SELECT setval(
  'engineer_id_seq',
  GREATEST((SELECT coalesce(max(id), 0) FROM engineer), 1),
  (SELECT coalesce(max(id), 0) FROM engineer) > 0);
ALTER TABLE engineer ALTER COLUMN id SET DEFAULT nextval('engineer_id_seq');

ALTER TABLE invoice ALTER COLUMN id DROP IDENTITY IF EXISTS;
CREATE SEQUENCE invoice_id_seq OWNED BY invoice.id;
SELECT setval(
  'invoice_id_seq',
  GREATEST((SELECT coalesce(max(id), 0) FROM invoice), 1),
  (SELECT coalesce(max(id), 0) FROM invoice) > 0);
ALTER TABLE invoice ALTER COLUMN id SET DEFAULT nextval('invoice_id_seq');

ALTER TABLE payroll_run ALTER COLUMN id DROP IDENTITY IF EXISTS;
CREATE SEQUENCE payroll_run_id_seq OWNED BY payroll_run.id;
SELECT setval(
  'payroll_run_id_seq',
  GREATEST((SELECT coalesce(max(id), 0) FROM payroll_run), 1),
  (SELECT coalesce(max(id), 0) FROM payroll_run) > 0);
ALTER TABLE payroll_run ALTER COLUMN id SET DEFAULT nextval('payroll_run_id_seq');

-- contract / project are plain int PKs minted with coalesce(max(id),0)+1: attach a
-- real sequence seeded past the current max.
CREATE SEQUENCE contract_id_seq OWNED BY contract.id;
SELECT setval(
  'contract_id_seq',
  GREATEST((SELECT coalesce(max(id), 0) FROM contract), 1),
  (SELECT coalesce(max(id), 0) FROM contract) > 0);
ALTER TABLE contract ALTER COLUMN id SET DEFAULT nextval('contract_id_seq');

CREATE SEQUENCE project_id_seq OWNED BY project.id;
SELECT setval(
  'project_id_seq',
  GREATEST((SELECT coalesce(max(id), 0) FROM project), 1),
  (SELECT coalesce(max(id), 0) FROM project) > 0);
ALTER TABLE project ALTER COLUMN id SET DEFAULT nextval('project_id_seq');
