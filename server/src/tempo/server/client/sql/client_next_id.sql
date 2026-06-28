-- client_next_id.sql — reserve the next client id from its sequence.
--
-- Called before create_client records any client fact: the handler threads this id
-- into the Client anchor and its profile in one transaction, so nothing is read back.
SELECT nextval('client_id_seq')::int AS id;
