-- 010_split_allocation.sql — the v2-split migration (ARCHITECTURE.md §7, ADR-007).
--
-- The centerpiece schema evolution: drop the denormalized `allocation.day_rate`
-- cache and temporally COALESCE the fragmented allocation rows back into whole
-- engagements with `range_agg`. The new WITHOUT OVERLAPS PK + PERIOD FKs are the
-- migration's own test harness — a bad transform is rejected inside the
-- transaction and rolls the whole file back.
--
-- Why no day_rate: the board query already derives charge rate from
-- engineer_role × rate_card (the two-hop temporal join, ADR-009); day_rate was a
-- redundant cache that only fragmented allocation history (adjacent rows differing
-- solely by the cached rate). Removing it changes no board output for any date —
-- the slider is the correctness oracle (ARCHITECTURE.md §7).
--
-- Transaction boundary: the migration runner (tempo/server/migrate) wraps each
-- file's statements in a single transaction and rolls the whole file back on any
-- failure, so this file is the body of ONE transaction without literal
-- BEGIN/COMMIT (a literal COMMIT would prematurely close the runner's transaction
-- and defeat the all-or-nothing validation this migration depends on).

-- The slim allocation: identical to the v1 table (002_facts.sql) minus day_rate.
-- Defined explicitly (not LIKE ... INCLUDING ALL) so the PK + PERIOD FKs get the
-- explicit constraint names and PERIOD FKs are actually present — LIKE copies
-- neither foreign keys nor would it produce the expected names after rename.
-- Constraints are named with the `_v2` suffix here and renamed below to the
-- from-scratch names (002_facts.sql), so the migrated schema is byte-identical
-- to a fresh slim build (ADR-022 explicit names).
CREATE TABLE allocation_v2 (
  engineer_id int NOT NULL,
  project_id  int NOT NULL,
  fraction    numeric(3,2) NOT NULL CHECK (fraction > 0 AND fraction <= 1),
  allocated_during daterange NOT NULL,
  CONSTRAINT allocation_v2_no_overlap
    PRIMARY KEY (engineer_id, project_id, allocated_during WITHOUT OVERLAPS),
  CONSTRAINT allocation_v2_within_employment
    FOREIGN KEY (engineer_id, PERIOD allocated_during)
    REFERENCES employment (engineer_id, PERIOD employed_during),
  CONSTRAINT allocation_v2_within_project
    FOREIGN KEY (project_id,  PERIOD allocated_during)
    REFERENCES project    (id,          PERIOD active_during)
);

-- range_agg merges adjacent AND overlapping periods into one multirange, then
-- unnest expands it back to one row per maximal contiguous segment. Grouping by
-- (engineer_id, project_id, fraction) keeps a genuine fraction change a real
-- boundary, while a rate-only change — no longer in the row and not in the group
-- key — is coalesced away. Genuine time gaps survive as separate segments.
INSERT INTO allocation_v2 (engineer_id, project_id, fraction, allocated_during)
SELECT engineer_id, project_id, fraction, unnest(range_agg(allocated_during))
FROM allocation
GROUP BY engineer_id, project_id, fraction;

-- Drop the v1 table. CASCADE removes the timesheet PERIOD FK that references it;
-- it is re-added below against the coalesced table, which re-validates every
-- existing timesheet day against the merged allocations (extra proof the coalesce
-- preserved coverage — a logged day outside the merged engagements would abort).
DROP TABLE allocation CASCADE;

ALTER TABLE allocation_v2 RENAME TO allocation;

-- Restore the from-scratch constraint/index names a fresh `CREATE TABLE
-- allocation` (002_facts.sql) would have produced, so the schema is identical to
-- a from-scratch slim build (the v2-split tag's tree stays internally
-- consistent; ADR-006) and the layer-1 constraint tests find the explicit
-- ADR-022 names (allocation_no_overlap / allocation_within_*).
-- Renaming a PK constraint also renames its backing index, so no separate
-- ALTER INDEX is needed.
ALTER TABLE allocation RENAME CONSTRAINT allocation_v2_no_overlap        TO allocation_no_overlap;
ALTER TABLE allocation RENAME CONSTRAINT allocation_v2_within_employment TO allocation_within_employment;
ALTER TABLE allocation RENAME CONSTRAINT allocation_v2_within_project    TO allocation_within_project;
ALTER TABLE allocation RENAME CONSTRAINT allocation_v2_fraction_check    TO allocation_fraction_check;
ALTER TABLE allocation RENAME CONSTRAINT allocation_v2_engineer_id_not_null      TO allocation_engineer_id_not_null;
ALTER TABLE allocation RENAME CONSTRAINT allocation_v2_project_id_not_null       TO allocation_project_id_not_null;
ALTER TABLE allocation RENAME CONSTRAINT allocation_v2_fraction_not_null         TO allocation_fraction_not_null;
ALTER TABLE allocation RENAME CONSTRAINT allocation_v2_allocated_during_not_null TO allocation_allocated_during_not_null;

-- Re-add the timesheet PERIOD FK dropped by the CASCADE above, with its original
-- explicit name (002_facts.sql, ADR-022). Adding it now validates the seeded
-- timesheet rows against the coalesced allocation: "a logged day must be covered
-- by an allocation" (ADR-008) still holds.
ALTER TABLE timesheet
  ADD CONSTRAINT timesheet_within_allocation
  FOREIGN KEY (engineer_id, project_id, PERIOD work_day)
  REFERENCES allocation (engineer_id, project_id, PERIOD allocated_during);
