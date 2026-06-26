-- account_by_username.sql — fetch a login account by its unique username (an email):
-- id, display name, linked engineer (nullable), and password hash. Drives POST
-- /api/login. Returns 0 or 1 rows. $1 = username.
SELECT id, display_name, engineer_id, password_hash
  FROM account
 WHERE username = $1;
