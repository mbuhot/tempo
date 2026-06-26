-- account_upsert.sql — DEV-ONLY: provision a login account (tempo/seed). Idempotent
-- via ON CONFLICT, so re-seeding never errors and never clobbers an existing row's
-- password. Never run by a migration: a deploy provisions real accounts itself.
-- $1 = username, $2 = display_name, $3 = role, $4 = password_hash (PHC string).
INSERT INTO account (username, display_name, role, password_hash)
VALUES ($1, $2, $3, $4)
ON CONFLICT (username) DO NOTHING;
