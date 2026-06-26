-- user_role_revoke.sql — revoke a role from an account effective from a date
-- (RevokeUserRole): cap the held period at the effective date (DELETE FOR PORTION OF),
-- leaving the history [start, effective) intact for audit. $1 = account id, $2 = role,
-- $3 = effective date.
DELETE FROM user_role
   FOR PORTION OF held_during FROM $3::date TO NULL
 WHERE account_id = $1 AND role = $2;
