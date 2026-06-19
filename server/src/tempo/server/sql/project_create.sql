-- project_create.sql — mint a new project identity (ID-ONLY anchor).
--
-- Step 1 of start_project (anchor → run → profile → plan, the run contained in its
-- contract by the project_within_contract PERIOD FK; the project's NAME is now a
-- project_profile fact and its budget/target a project_plan fact, both written
-- alongside, NOT columns here). The project id is an entity id reused across the
-- run/profile/plan period-rows; there is no IDENTITY on the anchor, so we mint a
-- fresh one with coalesce(max(id),0)+1 and RETURNING hands it back to thread into
-- the run, profile, and plan inserts.
INSERT INTO project (id)
VALUES ((SELECT coalesce(max(id), 0) + 1 FROM project))
RETURNING id;
