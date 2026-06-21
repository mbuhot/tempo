-- engineer_contact_current.sql — an engineer's CURRENT contact (name + contact
-- details) from the engineer_current view, which already exposes the
-- latest-version columns. $1 = engineer_id; an empty result means no such
-- engineer (the detail handler answers 404). Scalar columns only.
SELECT
  id AS engineer_id,
  name,
  email,
  phone,
  postal_address
FROM engineer_current
WHERE id = $1;
