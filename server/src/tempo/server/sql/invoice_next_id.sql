-- invoice_next_id.sql — reserve the next invoice id from its sequence.
--
-- Called before draft_invoice records any invoice fact: the handler threads this id
-- into the Invoice anchor, its subject, status, and lines in one transaction, so
-- nothing is read back.
SELECT nextval('invoice_id_seq')::int AS id;
