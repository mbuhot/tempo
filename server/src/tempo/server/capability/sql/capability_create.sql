-- capability_create.sql — insert the capability identity (ID-ONLY anchor) at a
-- reserved id.
--
-- The id is reserved up-front from capability_id_seq (capability_next_id) and
-- supplied as $1, so this is a plain insert with no RETURNING. The capability's
-- name/summary live in a separate capability_profile fact recorded alongside,
-- NOT a column here.
INSERT INTO capability (id) VALUES ($1);
