-- capability_skill_remove.sql — remove a skill from a capability's composition
-- from the effective date (RemoveCapabilitySkill): cap the mapped period at the
-- effective date (DELETE FOR PORTION OF), leaving the history [start, effective)
-- intact for audit. $1 = capability_id, $2 = skill_id, $3 = effective date.
DELETE FROM capability_skill
   FOR PORTION OF mapped_during FROM $3::date TO NULL
 WHERE capability_id = $1 AND skill_id = $2;
