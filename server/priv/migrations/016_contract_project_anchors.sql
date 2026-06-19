-- 016_contract_project_anchors.sql — split contract and project into an ID-ONLY
-- anchor + period-keyed facts, the same anchor/fact shape engineer (014) and
-- client (015) took. Contract and project move TOGETHER because project's PERIOD
-- FK (project_within_contract) targets contract: the two re-shapings are atomic.
--
-- Unlike engineer/client — whose anchor (`engineer`/`client`) already existed and
-- only shed columns — contract and project INTRODUCE their anchors here, by
-- RENAMING the live fact table out from under its old name and minting a fresh
-- id-only anchor under it. The KEY MECHANIC is that renaming a table/column carries
-- the existing PERIOD FKs with it automatically:
--   * RENAME contract -> contract_terms and its id -> contract_id makes
--     project_within_contract follow to contract_terms(contract_id, term).
--   * RENAME project -> project_run and its id -> project_id makes
--     allocation_within_project and invoice_within_project follow to
--     project_run(project_id, active_during).
-- So NO drop/re-add of those PERIOD FKs is needed — they re-point by rename.
--
-- TEMPORAL FLAVOURS introduced:
--   * contract_terms — VALID-TIME, read AS-OF. `term` IS the period (the engagement
--     window). Its WITHOUT OVERLAPS PK is the renamed contract_no_overlap.
--   * project_run    — VALID-TIME, read AS-OF. `active_during` is the existence /
--     containment window (and the target of the allocation/invoice PERIOD FKs).
--   * project_profile — APPEND-ONLY, read LATEST (period `recorded_during`,
--     transaction-time). Home of the old project NAME (now `title`) + a summary.
--   * project_plan    — APPEND-ONLY, read LATEST (period `planned_during`). NEW
--     attributes: budget + target_completion.
--
-- btree_gist (from 001) supplies the int-equality half of every WITHOUT OVERLAPS
-- GiST exclusion constraint, exactly as for the core fact tables.

-- contract -> anchor + terms ---------------------------------------------------
-- Rename the live contract table to contract_terms (term IS its period), rename its
-- id to contract_id, and rename its WITHOUT OVERLAPS PK. project_within_contract
-- follows the rename to contract_terms(contract_id, term) with no FK edits. Then
-- mint the id-only `contract` anchor from the distinct ids and add a plain FK back.
ALTER TABLE contract RENAME TO contract_terms;
ALTER TABLE contract_terms RENAME COLUMN id TO contract_id;
ALTER TABLE contract_terms RENAME CONSTRAINT contract_no_overlap TO contract_terms_no_overlap;
CREATE TABLE contract (id int PRIMARY KEY);
INSERT INTO contract (id) SELECT DISTINCT contract_id FROM contract_terms;
ALTER TABLE contract_terms ADD CONSTRAINT contract_terms_anchor_fkey FOREIGN KEY (contract_id) REFERENCES contract(id);

-- project -> anchor + run + profile + plan -------------------------------------
-- Rename the live project table to project_run (active_during is its existence
-- window) and its id to project_id; allocation_within_project and
-- invoice_within_project follow the rename to project_run(project_id,
-- active_during) with no FK edits. Mint the id-only `project` anchor and add a
-- plain FK back.
ALTER TABLE project RENAME TO project_run;
ALTER TABLE project_run RENAME COLUMN id TO project_id;
ALTER TABLE project_run RENAME CONSTRAINT project_no_overlap TO project_run_no_overlap;
CREATE TABLE project (id int PRIMARY KEY);
INSERT INTO project (id) SELECT DISTINCT project_id FROM project_run;
ALTER TABLE project_run ADD CONSTRAINT project_run_anchor_fkey FOREIGN KEY (project_id) REFERENCES project(id);

-- project_profile — the project's TITLE (the old name) + a summary, read LATEST.
-- Append-only; `recorded_during` carries the transaction-time character. Seeded
-- from project_run.name (still present until the DROP COLUMN below) so the board /
-- invoice / roster JSON is byte-identical, with summary ''. Open from 2024-01-01
-- so the latest read picks it up for every as-of date.
CREATE TABLE project_profile (
  project_id int NOT NULL REFERENCES project(id),
  title text NOT NULL,
  summary text NOT NULL,
  recorded_during daterange NOT NULL,
  CONSTRAINT project_profile_no_overlap PRIMARY KEY (project_id, recorded_during WITHOUT OVERLAPS)
);
INSERT INTO project_profile (project_id, title, summary, recorded_during)
SELECT project_id, name, '', daterange('2024-01-01', NULL, '[)') FROM project_run;

-- The latest-read projection over project_profile: DISTINCT ON (project_id) ordered
-- by lower(recorded_during) DESC gives the most-recently-effective profile per
-- project. Aliased project_id AS id so name-reading queries re-point to it.
CREATE VIEW project_current AS
SELECT DISTINCT ON (project_id) project_id AS id, title, summary
FROM project_profile ORDER BY project_id, lower(recorded_during) DESC;

-- The name has moved into project_profile.title; drop it from the run fact.
ALTER TABLE project_run DROP COLUMN name;

-- project_plan — NEW per-project attributes (budget + target_completion), read
-- LATEST. Append-only; `planned_during` carries the transaction-time character.
-- Seeded with the founding plans for the three demo projects (ids 100/200/300 in
-- the v1 fixture); open-ended from each project's run start.
CREATE TABLE project_plan (
  project_id int NOT NULL REFERENCES project(id),
  budget numeric(12,2) NOT NULL CHECK (budget >= 0),
  target_completion date NOT NULL,
  planned_during daterange NOT NULL,
  CONSTRAINT project_plan_no_overlap PRIMARY KEY (project_id, planned_during WITHOUT OVERLAPS)
);
INSERT INTO project_plan (project_id, budget, target_completion, planned_during) VALUES
  (100, 500000.00, DATE '2026-12-31', daterange('2024-01-01', NULL, '[)')),
  (200, 300000.00, DATE '2026-12-31', daterange('2025-06-01', NULL, '[)')),
  (300, 800000.00, DATE '2026-12-31', daterange('2025-01-01', NULL, '[)'));

-- The allocation/invoice PERIOD FKs already followed the project_run rename. Add
-- PLAIN FKs from those tables' project_id to the new project anchor too, so the
-- anchor is the referential root (mirrors contract_terms_anchor_fkey / the engineer
-- and client anchor FKs).
ALTER TABLE allocation ADD CONSTRAINT allocation_project_fkey FOREIGN KEY (project_id) REFERENCES project(id);
ALTER TABLE invoice    ADD CONSTRAINT invoice_project_fkey    FOREIGN KEY (project_id) REFERENCES project(id);
