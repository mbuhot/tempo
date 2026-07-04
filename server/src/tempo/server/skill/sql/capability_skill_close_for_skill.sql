-- capability_skill_close_for_skill.sql — cap all capability mappings of a skill
-- from a date (retire cascade, part of RetireSkill).
--
-- Close/cascade pattern, mirroring engineer_role_close_all: DELETE FOR PORTION OF
-- intersects [$end, ∞) with each mapping row: a row wholly after $end is dropped,
-- a row straddling $end keeps its [row.lower, $end) leftover. No @> filter — this
-- is intentionally broad, ending every capability the skill is mapped to.
-- $1 = skill_id, $2 = end date.
DELETE FROM capability_skill
   FOR PORTION OF mapped_during FROM $2::date TO NULL
 WHERE skill_id = $1;
