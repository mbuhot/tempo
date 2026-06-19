-- 015_client_facts.sql — move the client's NAME out of the client anchor into an
-- edit-grouped fact, leaving `client` an ID-ONLY referent. Mirrors 014 (engineer
-- facts) for the simpler client, which has only a NAME — so one fact table, one
-- Update command.
--
-- client_profile is an APPEND-ONLY fact read LATEST. Its period is named
-- `recorded_during` to signal the transaction-time character: a new edit is a new
-- row covering [effective, NULL), and the most-recently-effective row is the
-- current truth. Nothing here is a valid-time claim about the world; it is "the
-- client's profile as last recorded".
--
-- The fact:
--   * NOT NULL on every column (the read records are scalar-only — no Options).
--   * PK (client_id, recorded_during WITHOUT OVERLAPS): at most one row per client
--     per instant, so DISTINCT ON (client_id) ORDER BY the lower bound descending
--     yields exactly the latest (most-recently-effective) row.
--   * client_id REFERENCES client(id): a PLAIN (non-PERIOD) FK to the anchor.
--
-- btree_gist (from 001) supplies the int-equality half of the WITHOUT OVERLAPS
-- GiST exclusion constraint, exactly as for the core fact tables.

-- "the client's profile as last recorded" — the home of NAME after it leaves the
-- anchor.
CREATE TABLE client_profile (
  client_id int  NOT NULL REFERENCES client(id),
  name      text NOT NULL,
  recorded_during daterange NOT NULL,
  CONSTRAINT client_profile_no_overlap
    PRIMARY KEY (client_id, recorded_during WITHOUT OVERLAPS)
);

-- Seed -----------------------------------------------------------------------
-- Both the old client.name column and the new table coexist here (the DROP COLUMN
-- below is the last statement), so the founding name flows straight from the
-- anchor into client_profile — guaranteeing the post-refactor reads expose the
-- SAME name strings the board/invoice/roster JSON exposed before. recorded_during
-- is open from 2024-01-01 so the latest read picks it up for every as-of date.
INSERT INTO client_profile
  (client_id, name, recorded_during)
SELECT
  client.id,
  client.name,
  daterange('2024-01-01', NULL, '[)')
FROM client;

-- Current-name view ----------------------------------------------------------
-- The latest-read projection over client_profile: DISTINCT ON (client_id) ordered
-- by the lower bound of recorded_during descending gives the most-recently-
-- effective profile per client. Aliased columns (client_id AS id, plus name)
-- match the shape the name-reading queries expect from the old `client` table, so
-- each re-points with a one-word swap (JOIN client_current client ON …).
--
-- ORDER BY lower(recorded_during) DESC: rows never overlap (WITHOUT OVERLAPS),
-- and the latest edit is the one with the greatest start, so its lower bound is
-- the maximal one — the row whose [effective, NULL) span is currently in force.
CREATE VIEW client_current AS
SELECT DISTINCT ON (client_id)
  client_id AS id,
  name
FROM client_profile
ORDER BY client_id, lower(recorded_during) DESC;

-- Drop the anchor's name --------------------------------------------------------
-- client is now ID-ONLY. Every NAME read goes through client_current; the anchor's
-- id still backs the existing FKs (contract, and the new client_profile above).
ALTER TABLE client DROP COLUMN name;
