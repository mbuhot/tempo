-- contract_next_id.sql — reserve the next contract id from its sequence.
--
-- Called before sign_contract records any contract fact: the handler threads this id
-- into the Contract anchor and its terms in one transaction, so nothing is read back.
SELECT nextval('contract_id_seq')::int AS id;
