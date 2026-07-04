-- capability_next_id.sql — reserve the next capability id from its sequence.
--
-- Called before create_capability records the anchor: the handler threads this id
-- into the capability anchor and its capability_profile fact in one transaction,
-- so nothing is read back.
SELECT nextval('capability_id_seq')::int AS id;
