-- project_create.sql — insert the project identity (ID-ONLY anchor) at a reserved id.
--
-- Step 1 of start_project. The id is reserved up-front from project_id_seq
-- (project_next_id) and supplied as $1, so this is a plain insert with no RETURNING.
-- The run/profile/plan are separate facts recorded alongside.
INSERT INTO project (id) VALUES ($1);
