-- project_capability_clear.sql — step 1 of the FOR-PORTION-OF set. DELETE FOR
-- PORTION OF carves the target window [$2, $3) out of whatever (project, capability)
-- rows cover any part of it, re-inserting the before/after remainders at their
-- original target_level/quantity (keeping their original audit_id). Step 2
-- (project_capability_set.sql) then inserts the new line over the now-vacant
-- window.
--
-- `ON CONFLICT` cannot target the WITHOUT OVERLAPS PK (a GiST exclusion constraint),
-- so the set is delete-then-insert run in ONE transaction by the handler. A first
-- set over a vacant window deletes 0 rows (a harmless no-op); never branch on the
-- affected-row count. $1 = project_id, $2 = from, $3 = to, $4 = capability_id.
DELETE FROM project_capability
   FOR PORTION OF required_during FROM $2::date TO $3::date
 WHERE project_id = $1 AND capability_id = $4;
