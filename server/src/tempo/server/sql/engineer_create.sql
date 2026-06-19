-- engineer_create.sql — mint a new engineer identity (ID-ONLY anchor).
--
-- Step 1 of onboarding (identity → employment → role, each contained in the last
-- by its PERIOD FK; the engineer's NAME is now a separate engineer_contact fact,
-- written alongside, NOT a column here). `engineer.id` is GENERATED ALWAYS AS
-- IDENTITY, so the caller supplies nothing; RETURNING hands back the minted id to
-- thread into the employment, role, and contact inserts.
INSERT INTO engineer DEFAULT VALUES
RETURNING id;
