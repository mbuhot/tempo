-- contract_terms_open.sql — open a contract's term (the engagement window).
--
-- Step 2 of sign_contract: insert the contract_terms row over [$3, $4) for contract
-- $1, resolving the client by NAME to its id. The NAME left the `client` anchor for
-- the edit-grouped client_profile fact, so the resolver reads it through the
-- `client_current` view (latest profile per client). term = daterange($3, $4, '[)')
-- is the engagement window; $4 may be NULL for an open-ended term. $1 = contract_id,
-- $2 = client name, $3 = valid_from, $4 = valid_to.
INSERT INTO contract_terms (contract_id, client_id, term)
VALUES (
  $1,
  (SELECT id FROM client_current WHERE name = $2),
  daterange($3::date, $4::date, '[)')
);
