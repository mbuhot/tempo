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
-- canonical constraint names and PERIOD FKs are actually present — LIKE copies
-- neither foreign keys nor would it produce the expected names after rename.
CREATE TABLE allocation_v2 (
  engineer_id int NOT NULL,
  project_id  int NOT NULL,
  fraction    numeric(3,2) NOT NULL CHECK (fraction > 0 AND fraction <= 1),
  valid_at    daterange NOT NULL,
  PRIMARY KEY (engineer_id, project_id, valid_at WITHOUT OVERLAPS),
  FOREIGN KEY (engineer_id, PERIOD valid_at) REFERENCES employment (engineer_id, PERIOD valid_at),
  FOREIGN KEY (project_id,  PERIOD valid_at) REFERENCES project    (id,          PERIOD valid_at)
);

-- range_agg merges adjacent AND overlapping periods into one multirange, then
-- unnest expands it back to one row per maximal contiguous segment. Grouping by
-- (engineer_id, project_id, fraction) keeps a genuine fraction change a real
-- boundary, while a rate-only change — no longer in the row and not in the group
-- key — is coalesced away. Genuine time gaps survive as separate segments.
INSERT INTO allocation_v2 (engineer_id, project_id, fraction, valid_at)
SELECT engineer_id, project_id, fraction, unnest(range_agg(valid_at))
FROM allocation
GROUP BY engineer_id, project_id, fraction;

-- Drop the v1 table. CASCADE removes the timesheet PERIOD FK that references it;
-- it is re-added below against the coalesced table, which re-validates every
-- existing timesheet day against the merged allocations (extra proof the coalesce
-- preserved coverage — a logged day outside the merged engagements would abort).
DROP TABLE allocation CASCADE;

ALTER TABLE allocation_v2 RENAME TO allocation;

-- Restore the canonical constraint/index names a fresh `CREATE TABLE allocation`
-- would have produced, so the schema is identical to a from-scratch slim build
-- (the v2-split tag's tree stays internally consistent; ADR-006) and the
-- layer-1 constraint tests still find allocation_pkey / the PERIOD-FK names.
ALTER INDEX allocation_v2_pkey RENAME TO allocation_pkey;
ALTER TABLE allocation RENAME CONSTRAINT allocation_v2_engineer_id_valid_at_fkey TO allocation_engineer_id_valid_at_fkey;
ALTER TABLE allocation RENAME CONSTRAINT allocation_v2_project_id_valid_at_fkey  TO allocation_project_id_valid_at_fkey;
ALTER TABLE allocation RENAME CONSTRAINT allocation_v2_fraction_check            TO allocation_fraction_check;
ALTER TABLE allocation RENAME CONSTRAINT allocation_v2_engineer_id_not_null      TO allocation_engineer_id_not_null;
ALTER TABLE allocation RENAME CONSTRAINT allocation_v2_project_id_not_null       TO allocation_project_id_not_null;
ALTER TABLE allocation RENAME CONSTRAINT allocation_v2_fraction_not_null         TO allocation_fraction_not_null;
ALTER TABLE allocation RENAME CONSTRAINT allocation_v2_valid_at_not_null         TO allocation_valid_at_not_null;

-- Re-add the timesheet PERIOD FK dropped by the CASCADE above, with its original
-- name. Adding it now validates the seeded timesheet rows against the coalesced
-- allocation: "a logged day must be covered by an allocation" (ADR-008) still holds.
ALTER TABLE timesheet
  ADD CONSTRAINT timesheet_engineer_id_project_id_work_day_fkey
  FOREIGN KEY (engineer_id, project_id, PERIOD work_day)
  REFERENCES allocation (engineer_id, project_id, PERIOD valid_at);
