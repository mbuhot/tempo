-- effective_permissions.sql — the set of permission keys an account holds RIGHT NOW:
-- the union of role_permission over every role the account holds, both periods covering
-- CURRENT_DATE. The authorization gate checks each command/read permission against this
-- set. $1 = account id.
SELECT DISTINCT rp.permission
  FROM user_role ur
  JOIN role_permission rp ON rp.role = ur.role
 WHERE ur.account_id = $1
   AND ur.held_during @> CURRENT_DATE
   AND rp.granted_during @> CURRENT_DATE;
