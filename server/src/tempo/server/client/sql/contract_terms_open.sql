-- contract_terms_open.sql — open a contract's term (resolving the client by name to
-- its id). Last param is the audit_id. $1 = contract_id, $2 = client name,
-- $3 = from, $4 = to.
INSERT INTO contract_terms (contract_id, client_id, term, audit_id)
VALUES (
  $1,
  (SELECT id FROM client_current WHERE name = $2),
  daterange($3::date, $4::date, '[)'),
  $5
);
