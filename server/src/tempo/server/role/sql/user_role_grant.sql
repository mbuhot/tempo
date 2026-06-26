-- user_role_grant.sql — grant a role to an account effective from a date (GrantUserRole).
-- Caps any current period at the effective date then opens a fresh [effective, ∞), so a
-- re-grant is idempotent — mirroring engineer_role_upsert's close-then-open. $1 = account
-- id, $2 = role, $3 = effective date, $4 = audit_id (the journal event for this grant).
WITH capped AS (
  DELETE FROM user_role
     FOR PORTION OF held_during FROM $3::date TO NULL
   WHERE account_id = $1 AND role = $2
)
INSERT INTO user_role (account_id, role, held_during, audit_id)
VALUES ($1, $2, daterange($3::date, NULL, '[)'), $4);
