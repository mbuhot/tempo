-- skill_create.sql — insert the skill identity (ID-ONLY anchor) at a reserved id.
--
-- The id is reserved up-front from skill_id_seq (skill_next_id) and supplied as
-- $1, so this is a plain insert with no RETURNING. The skill's name/summary live
-- in a separate skill_profile fact recorded alongside, NOT a column here.
INSERT INTO skill (id) VALUES ($1);
