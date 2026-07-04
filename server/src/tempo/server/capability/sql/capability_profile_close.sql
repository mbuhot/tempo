-- capability_profile_close.sql — cap a capability's profile at the effective date
-- (RetireCapability): cap the defined period at the effective date (DELETE FOR
-- PORTION OF), leaving the history [start, effective) intact for audit.
-- $1 = capability_id, $2 = effective date.
DELETE FROM capability_profile
   FOR PORTION OF defined_during FROM $2::date TO NULL
 WHERE capability_id = $1;
