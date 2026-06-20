-- engineer_contact_open.sql — open an engineer's founding contact (carries the
-- NAME; the anchor is id-only). Last param is the audit_id.
-- $1 = engineer_id, $2 = name, $3 = email, $4 = phone, $5 = postal, $6 = from.
INSERT INTO engineer_contact
  (engineer_id, name, email, phone, postal_address, recorded_during, audit_id)
VALUES ($1, $2, $3, $4, $5, daterange($6::date, NULL, '[)'), $7);
