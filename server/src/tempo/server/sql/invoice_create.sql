-- invoice_create.sql — insert the invoice identity (ID-ONLY anchor) at a reserved id.
--
-- Step 1 of draft_invoice. The id is reserved up-front from invoice_id_seq
-- (invoice_next_id) and supplied as $1, so this is a plain insert with no RETURNING.
-- The subject/status/lines are separate facts recorded alongside.
INSERT INTO invoice (id) VALUES ($1);
