-- skill_next_id.sql — reserve the next skill id from its sequence.
--
-- Called before create_skill records the anchor: the handler threads this id
-- into the skill anchor and its skill_profile fact in one transaction, so
-- nothing is read back.
SELECT nextval('skill_id_seq')::int AS id;
