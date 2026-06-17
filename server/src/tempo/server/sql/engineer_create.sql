-- engineer_create.sql — mint a new engineer identity.
--
-- Step 1 of onboarding (identity → employment → role, each contained in the
-- last by its PERIOD FK). `engineer.id` is GENERATED ALWAYS AS IDENTITY, so the
-- caller never supplies it; RETURNING hands back the minted id to thread into
-- the employment and role inserts. $1 = name.
INSERT INTO engineer (name)
VALUES ($1)
RETURNING id;
