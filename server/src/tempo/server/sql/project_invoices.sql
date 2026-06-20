-- project_invoices.sql — one project's invoices for the detail read model (GET
-- /api/projects/:id; FR-CP7). Params: $1 = project_id, $2 = as-of.
--
-- invoice_list scoped to a single project: same columns and shape as invoice_list
-- (so it decodes through the reused Invoice codec) but filtered to
-- invoice_subject.project_id = $1. The status shown is the row covering $2 via `@>`,
-- so scrubbing the rail back shows a draft before its issue date (FR-F4); an invoice
-- with no status covering $2 is dropped (the status JOIN is INNER). The project name
-- is THIS project's title; the client name is reached through the project's run to
-- its contract's client (correlated LIMIT-1 so a multi-period project does not
-- multiply rows). Total is coalesce(Σ amount, 0) over the snapshot lines. Ordered by
-- billing month then id.
SELECT
  invoice.id,
  coalesce((
    SELECT project.title FROM project_current project
     WHERE project.id = invoice_subject.project_id
     LIMIT 1
  ), '') AS project,
  coalesce((
    SELECT client.name
      FROM project_run
      JOIN contract_terms ON contract_terms.contract_id = project_run.contract_id
      JOIN client_current client ON client.id = contract_terms.client_id
     WHERE project_run.project_id = invoice_subject.project_id
     LIMIT 1
  ), '') AS client,
  lower(invoice_subject.billing_period) AS billing_from,
  upper(invoice_subject.billing_period) AS billing_to,
  invoice_status.status,
  coalesce((
    SELECT sum(invoice_line.amount)
      FROM invoice_line
     WHERE invoice_line.invoice_id = invoice.id
  ), 0)::numeric AS total
FROM invoice
JOIN invoice_subject ON invoice_subject.invoice_id = invoice.id
                    AND invoice_subject.project_id = $1
JOIN invoice_status ON invoice_status.invoice_id = invoice.id
                   AND invoice_status.status_during @> $2::date
ORDER BY lower(invoice_subject.billing_period), invoice.id;
