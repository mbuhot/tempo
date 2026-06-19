-- contract_create.sql — mint a new contract identity (ID-ONLY anchor).
--
-- Step 1 of sign_contract (anchor → terms). The contract id is an entity id reused
-- across the contract_terms period-rows; there is no IDENTITY on the anchor, so we
-- mint a fresh one with coalesce(max(id),0)+1 and RETURNING hands it back to thread
-- into the terms insert.
INSERT INTO contract (id)
VALUES ((SELECT coalesce(max(id), 0) + 1 FROM contract))
RETURNING id;
