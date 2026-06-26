-- account_by_username.sql — fetch a login account's display name, role, and password
-- hash by its unique username (an email). Drives POST /api/login: the handler verifies
-- the password against the hash and maps the role to a Principal. Returns 0 or 1 rows.
-- $1 = username.
SELECT display_name, role, password_hash
  FROM account
 WHERE username = $1;
