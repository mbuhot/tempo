-- engineer_create.sql — insert the engineer identity (ID-ONLY anchor) at a reserved id.
--
-- Step 1 of onboarding. The id is reserved up-front from engineer_id_seq
-- (engineer_next_id) and supplied as $1, so this is a plain insert with no
-- RETURNING. The engineer's NAME lives in a separate engineer_contact fact recorded
-- alongside, NOT a column here.
INSERT INTO engineer (id) VALUES ($1);
