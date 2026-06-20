-- engineer_next_id.sql — reserve the next engineer id from its sequence.
--
-- Called before onboard records any engineer fact: the handler threads this id into
-- the Engineer anchor and every fact contained by it (employment, role, contact) in
-- one transaction, so nothing is read back.
SELECT nextval('engineer_id_seq')::int AS id;
