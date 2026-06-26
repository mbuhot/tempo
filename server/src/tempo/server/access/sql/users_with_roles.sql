-- users_with_roles.sql — every account with the roles it holds as-of CURRENT_DATE (one
-- row per account/role; an account with no current role yields a single row with a NULL
-- role). The Access page groups rows into one entry per account. $1 has no params.
SELECT a.id, a.username, a.display_name, a.engineer_id, ur.role
  FROM account a
  LEFT JOIN user_role ur
    ON ur.account_id = a.id AND ur.held_during @> CURRENT_DATE
 ORDER BY a.display_name, a.id, ur.role;
