-- skill_profile_close.sql — cap a skill's profile at the effective date
-- (RetireSkill): cap the defined period at the effective date (DELETE FOR
-- PORTION OF), leaving the history [start, effective) intact for audit.
-- $1 = skill_id, $2 = effective date.
DELETE FROM skill_profile
   FOR PORTION OF defined_during FROM $2::date TO NULL
 WHERE skill_id = $1;
