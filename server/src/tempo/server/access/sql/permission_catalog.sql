-- permission_catalog.sql — every permission key + description, for the Access matrix
-- view's row labels.
SELECT key, description FROM permission ORDER BY key;
