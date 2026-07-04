-- capability_skill_upsert.sql — set the weight a skill contributes to a capability
-- from $3 onward (delete-then-insert semantics), mirroring user_role_grant: caps
-- any current period at the effective date then opens a fresh [effective, ∞), so
-- a re-weight is idempotent — the DEFERRABLE PK covers the close-then-open over
-- an open span. $1 = capability_id, $2 = skill_id, $3 = effective, $4 = weight,
-- $5 = audit_id.
WITH capped AS (
  DELETE FROM capability_skill
     FOR PORTION OF mapped_during FROM $3::date TO NULL
   WHERE capability_id = $1 AND skill_id = $2
)
INSERT INTO capability_skill (capability_id, skill_id, weight, mapped_during, audit_id)
VALUES ($1, $2, $4, daterange($3::date, NULL, '[)'), $5);
