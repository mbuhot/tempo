-- account_upsert.sql — DEV-ONLY: provision a login account (tempo/seed). engineer_id is
-- derived from the username when it matches an engineer's email (NULL otherwise), so a
-- person's account links to their engineer record for ownership checks. Idempotent via
-- ON CONFLICT, so re-seeding never errors and never clobbers an existing row.
-- $1 = username, $2 = display_name, $3 = password_hash.
INSERT INTO account (username, display_name, engineer_id, password_hash)
SELECT $1, $2, (SELECT id FROM engineer_current WHERE email = $1), $3
ON CONFLICT (username) DO NOTHING;
