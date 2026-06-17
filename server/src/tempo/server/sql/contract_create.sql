-- contract_create.sql — assert a new client engagement (sign_contract).
--
-- A plain INSERT (write pattern 1). The contract id is NOT generated: it is an
-- entity id reused across period-rows, so we mint a fresh one with
-- coalesce(max(id),0)+1. The command carries the client by NAME, resolved to
-- client_id via a subquery. term = daterange($2, $3, '[)') is the engagement
-- window; $3 may be NULL for an open-ended term.
INSERT INTO contract (id, client_id, term)
VALUES (
  (SELECT coalesce(max(id), 0) + 1 FROM contract),
  (SELECT id FROM client WHERE name = $1),
  daterange($2::date, $3::date, '[)')
)
RETURNING id;
