-- project_next_id.sql — reserve the next project id from its sequence.
--
-- Called before start_project records any project fact: the handler threads this id
-- into the Project anchor, its run, profile, and plan in one transaction, so nothing
-- is read back.
SELECT nextval('project_id_seq')::int AS id;
