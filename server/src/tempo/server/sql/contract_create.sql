-- contract_create.sql — insert the contract identity (ID-ONLY anchor) at a reserved id.
--
-- Step 1 of sign_contract. The id is reserved up-front from contract_id_seq
-- (contract_next_id) and supplied as $1, so this is a plain insert with no RETURNING.
-- The engagement term lives in a separate contract_terms fact recorded alongside.
INSERT INTO contract (id) VALUES ($1);
