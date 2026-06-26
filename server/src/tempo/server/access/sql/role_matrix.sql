-- role_matrix.sql — the (role, permission) grants in force as-of CURRENT_DATE: the matrix
-- the Access page renders. The client groups rows by role.
SELECT rp.role, rp.permission
  FROM role_permission rp
 WHERE rp.granted_during @> CURRENT_DATE
 ORDER BY rp.role, rp.permission;
