-- account_by_id.sql — the journal display name and linked engineer for an account id
-- (the id carried in the signed session cookie). Used to build the request Principal
-- before resolving its effective permissions. Returns 0 or 1 rows. $1 = account id.
SELECT display_name, engineer_id
  FROM account
 WHERE id = $1;
