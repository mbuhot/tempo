-- 014_engineer_facts.sql — move the engineer's NAME (and its companions) out of
-- the engineer anchor into edit-grouped facts, leaving `engineer` an ID-ONLY
-- referent.
--
-- The core fact tables (employment, engineer_role, leave) are VALID-TIME facts
-- read AS-OF: their period asserts "true in the world over this span". The three
-- tables introduced here are a DIFFERENT temporal flavour — edit-grouped,
-- APPEND-ONLY, read LATEST. Their period is named `recorded_during` to signal the
-- transaction-time character: a new edit is a new row covering [effective, NULL),
-- and the most-recently-effective row is the current truth. Nothing here is a
-- valid-time claim about the world; it is "the contact/banking/emergency details
-- as last recorded".
--
-- Each fact:
--   * NOT NULL on every column (the read records are scalar-only — no Options).
--   * account_no is TEXT, never numeric — it may carry leading zeros.
--   * PK (engineer_id, recorded_during WITHOUT OVERLAPS): at most one row per
--     engineer per instant, so DISTINCT ON (engineer_id) ORDER BY the lower bound
--     descending yields exactly the latest (most-recently-effective) row.
--   * engineer_id REFERENCES engineer(id): a PLAIN (non-PERIOD) FK to the anchor.
--     These are properties of the PERSON, not facts contained by employment, so
--     they are NOT in the PERIOD-FK containment chain — an ex-employee still has
--     a name and bank account on file.
--
-- btree_gist (from 001) supplies the int-equality half of the WITHOUT OVERLAPS
-- GiST exclusion constraint, exactly as for the core fact tables.

-- "the engineer's contact details as last recorded" — the home of NAME after it
-- leaves the anchor.
CREATE TABLE engineer_contact (
  engineer_id    int  NOT NULL REFERENCES engineer(id),
  name           text NOT NULL,
  email          text NOT NULL,
  phone          text NOT NULL,
  postal_address text NOT NULL,
  recorded_during daterange NOT NULL,
  CONSTRAINT engineer_contact_no_overlap
    PRIMARY KEY (engineer_id, recorded_during WITHOUT OVERLAPS)
);

-- "the engineer's banking details as last recorded".
CREATE TABLE engineer_banking (
  engineer_id  int  NOT NULL REFERENCES engineer(id),
  bank         text NOT NULL,
  branch       text NOT NULL,
  account_no   text NOT NULL,   -- text: preserves leading zeros
  account_name text NOT NULL,
  recorded_during daterange NOT NULL,
  CONSTRAINT engineer_banking_no_overlap
    PRIMARY KEY (engineer_id, recorded_during WITHOUT OVERLAPS)
);

-- "the engineer's emergency contact as last recorded".
CREATE TABLE engineer_emergency (
  engineer_id int  NOT NULL REFERENCES engineer(id),
  relation    text NOT NULL,
  name        text NOT NULL,
  phone       text NOT NULL,
  email       text NOT NULL,
  recorded_during daterange NOT NULL,
  CONSTRAINT engineer_emergency_no_overlap
    PRIMARY KEY (engineer_id, recorded_during WITHOUT OVERLAPS)
);

-- Seed -----------------------------------------------------------------------
-- Both the old engineer.name column and the new tables coexist here (the DROP
-- COLUMN below is the last statement), so the founding name flows straight from
-- the anchor into engineer_contact — guaranteeing the post-refactor reads expose
-- the SAME name strings the board/financials JSON exposed before. The companion
-- columns are deterministic demo values (no factory randomness). recorded_during
-- is open from 2024-01-01 so the latest read picks it up for every as-of date.

-- Contact: NAME sourced from the anchor; email/phone/postal are deterministic.
INSERT INTO engineer_contact
  (engineer_id, name, email, phone, postal_address, recorded_during)
SELECT
  engineer.id,
  engineer.name,
  lower(replace(engineer.name, ' ', '.')) || '@alembic.com.au',
  '+61 400 000 00' || engineer.id::text,
  engineer.id::text || ' Demo St, Brisbane',
  daterange('2024-01-01', NULL, '[)')
FROM engineer
WHERE engineer.id IN (1, 2, 3);

-- Banking: account_name = the engineer name; branch/account_no carry the id so
-- every engineer's row is distinct and deterministic.
INSERT INTO engineer_banking
  (engineer_id, bank, branch, account_no, account_name, recorded_during)
VALUES
  (1, 'Big Bank', '061', '00123451', 'Priya Sharma', daterange('2024-01-01', NULL, '[)')),
  (2, 'Big Bank', '062', '00123452', 'Marcus Chen',  daterange('2024-01-01', NULL, '[)')),
  (3, 'Big Bank', '063', '00123453', 'Aisha Okafor', daterange('2024-01-01', NULL, '[)'));

-- Emergency: a plausible relation/name/phone/email per engineer.
INSERT INTO engineer_emergency
  (engineer_id, relation, name, phone, email, recorded_during)
VALUES
  (1, 'spouse',  'Rohan Sharma',  '+61 400 100 001', 'rohan.sharma@example.com',  daterange('2024-01-01', NULL, '[)')),
  (2, 'parent',  'Linda Chen',    '+61 400 100 002', 'linda.chen@example.com',    daterange('2024-01-01', NULL, '[)')),
  (3, 'sibling', 'Tunde Okafor',  '+61 400 100 003', 'tunde.okafor@example.com',  daterange('2024-01-01', NULL, '[)'));

-- Current-name view ----------------------------------------------------------
-- The latest-read projection over engineer_contact: DISTINCT ON (engineer_id)
-- ordered by the lower bound of recorded_during descending gives the most-
-- recently-effective contact per engineer. Aliased columns (engineer_id AS id,
-- plus name/email/phone/postal_address) match the shape the 8 name-reading
-- queries expect from the old `engineer` table, so each re-points with a one-word
-- swap (JOIN engineer_current engineer ON …) and its `engineer.name`/`engineer.id`
-- references are unchanged.
--
-- ORDER BY lower(recorded_during) DESC: rows never overlap (WITHOUT OVERLAPS),
-- and the latest edit is the one with the greatest start, so its lower bound is
-- the maximal one — the row whose [effective, NULL) span is currently in force.
CREATE VIEW engineer_current AS
SELECT DISTINCT ON (engineer_id)
  engineer_id AS id,
  name,
  email,
  phone,
  postal_address
FROM engineer_contact
ORDER BY engineer_id, lower(recorded_during) DESC;

-- Drop the anchor's name --------------------------------------------------------
-- engineer is now ID-ONLY. Every NAME read goes through engineer_current; the
-- anchor's id still backs the existing FKs (employment, engineer_role, and the
-- three new facts above).
ALTER TABLE engineer DROP COLUMN name;
