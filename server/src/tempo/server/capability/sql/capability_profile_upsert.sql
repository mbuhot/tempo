-- capability_profile_upsert.sql — record a capability profile from $2 onward
-- (delete-then-insert semantics). The temporal DELETE clips the row covering $2 to
-- [start, $2) and removes any rows that start at or after $2, then inserts
-- [$2, NULL) with the new name/summary. The founding CreateCapability write and a
-- later DefineCapability are the SAME fact, so this one query serves both.
-- $1 = capability_id, $2 = effective, $3 = name, $4 = summary, $5 = audit_id.
WITH deleted AS (
  DELETE FROM capability_profile
     FOR PORTION OF defined_during FROM $2::date TO NULL
   WHERE capability_id = $1
)
INSERT INTO capability_profile (capability_id, name, summary, defined_during, audit_id)
VALUES ($1, $3, $4, daterange($2::date, NULL, '[)'), $5);
