-- engineer_contact_revise.sql — record new contact details from $2 onward (the
-- Change pattern). FOR PORTION OF sets the new values + audit_id on the [$2, NULL)
-- portion of the covering row; PG carves off the unchanged [start, $2) remainder
-- keeping its original audit_id. $1 = engineer_id, $2 = effective, $3 = name,
-- $4 = email, $5 = phone, $6 = postal, $7 = audit_id.
UPDATE engineer_contact
   FOR PORTION OF recorded_during FROM $2::date TO NULL
   SET name = $3, email = $4, phone = $5, postal_address = $6, audit_id = $7
 WHERE engineer_id = $1
   AND recorded_during @> $2::date;
