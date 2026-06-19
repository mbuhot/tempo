-- invoice_header.sql — one invoice's header for the detail read model
-- (GET /api/invoices/:id). Same projection as invoice_list (project + client
-- name, billing month, status AS OF $2, line total) for a single invoice.
--
-- Params: $1 = invoice_id, $2 = as-of date. The status shown is the row covering
-- $2 (FR-F4). Unlike the list, the status JOIN is LEFT so the header still
-- returns for an as-of date with no covering status (status NULL), letting the
-- detail endpoint distinguish "no such invoice" (no row) from "exists but no
-- status as of this date" (a row with NULL status). The caller coalesces a NULL
-- status to "" before mapping to the shared read type.
SELECT
  invoice.id,
  coalesce((
    SELECT project.title FROM project_current project
     WHERE project.id = invoice.project_id
     LIMIT 1
  ), '') AS project,
  coalesce((
    SELECT client.name
      FROM project_run
      JOIN contract_terms ON contract_terms.contract_id = project_run.contract_id
      JOIN client_current client ON client.id = contract_terms.client_id
     WHERE project_run.project_id = invoice.project_id
     LIMIT 1
  ), '') AS client,
  lower(invoice.billing_period) AS billing_from,
  upper(invoice.billing_period) AS billing_to,
  coalesce((
    SELECT invoice_status.status FROM invoice_status
     WHERE invoice_status.invoice_id = invoice.id
       AND invoice_status.status_during @> $2::date
  ), '') AS status,
  coalesce((
    SELECT sum(invoice_line.amount)
      FROM invoice_line
     WHERE invoice_line.invoice_id = invoice.id
  ), 0)::numeric AS total
FROM invoice
WHERE invoice.id = $1;
