-- client_create.sql — insert the client identity (ID-ONLY anchor) at a reserved id.
--
-- Step 1 of create_client. The id is reserved up-front from client_id_seq
-- (client_next_id) and supplied as $1, so this is a plain insert with no RETURNING.
-- The client profile lives in a separate client_profile fact recorded alongside.
INSERT INTO client (id) VALUES ($1);
