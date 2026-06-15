-- 001_init.sql — extension + identity tables (v1-wide schema; ARCHITECTURE.md §4).
--
-- btree_gist MUST come first: a WITHOUT OVERLAPS primary key compiles to a GiST
-- exclusion constraint, and the int + daterange keys used throughout the fact
-- tables otherwise fail with "data type integer has no default operator class
-- for access method gist" (verified by spike P1-T01). Equality over the scalar
-- key columns is the btree_gist contribution; the range column supplies overlap.
CREATE EXTENSION IF NOT EXISTS btree_gist;

-- Identity tables — durable referents. Their ids never expire; everything
-- time-varying about an engineer or client is a separate fact table keyed back
-- to these ids (ADR-004).
CREATE TABLE engineer (
  id   int GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  name text NOT NULL
);

CREATE TABLE client (
  id   int GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  name text NOT NULL
);
