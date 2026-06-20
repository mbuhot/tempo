-- client_contracts.sql — one client's contract terms for the detail read model
-- (GET /api/clients/:id; the ContractRow list). Params: $1 = client_id,
-- $2 = as-of (for the active flag only).
--
-- Every contract_terms period-row for the client, decomposed to plain dates:
-- contract_id, lower(term) AS valid_from, upper(term) AS valid_to (non-null for
-- every seed row — all bounded at 2027-01-01). `active` is (term @> $2): the as-of
-- marks each contract active/ended per FR-CP1 without hiding it, so the whole list
-- is returned regardless of $2. Ordered oldest-first then by contract_id.
SELECT
  contract_terms.contract_id,
  lower(contract_terms.term) AS valid_from,
  upper(contract_terms.term) AS valid_to,
  (contract_terms.term @> $2::date) AS active
FROM contract_terms
WHERE contract_terms.client_id = $1
ORDER BY lower(contract_terms.term), contract_terms.contract_id;
