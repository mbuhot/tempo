-- invoice_list.sql — the invoices-table read model (FR-F1/FR-F4). One row per
-- invoice: the durable subject (project + client name, billing month) plus its
-- status AS OF $1, its line total (Σ invoice_line.amount), and the issue/pay
-- transition dates.
--
-- issued_at/paid_at. The lower bound of the issued/paid status span — the day the
-- issue_invoice/pay_invoice transition occurred — or NULL when that transition has
-- not happened as-of $1 (the transition day is after the rail date, or never).
-- The `?` alias suffix forces Squirrel to generate Option(Date) (the seed has no
-- unissued/unpaid invoice, so it would otherwise infer non-null and decode-fail).
-- The as-of status above still resolves independently via @>.
--
-- Param: $1 = as-of date. The status shown is the row covering $1 via `@>`, so
-- scrubbing the slider back shows a `draft` before its issue date (FR-F4). An
-- invoice with no status covering $1 (e.g. as-of before the billing month) is
-- dropped — the status JOIN is not a LEFT JOIN, so only invoices that "exist as
-- of $1" are listed.
--
-- Name resolution. The durable subject (project_id, billing_period) lives in the
-- 1:1 immutable invoice_subject fact, INNER JOINed here. `project_id` is a project
-- ENTITY id whose names are stable across its period-rows in the seed, so a
-- correlated LIMIT-1 subquery picks one name without multiplying the row by every
-- period version. An invoice whose project entity has no project row at all yields
-- NULL names (coalesced to '').
--
-- Total. coalesce(Σ amount, 0) over the snapshot lines — an invoice drafted with
-- no billable lines totals 0 rather than vanishing.
--
-- Keyset pagination (#12). Stable total order is (lower(billing_period), id) —
-- the existing display order plus the unique id tiebreaker. The cursor names the
-- last row already returned: $2 = its billing_from, $3 = its id; a row is on the
-- NEXT page when (billing_from, id) sorts strictly after (row > cursor). The first
-- page passes the sentinel ('0001-01-01', 0), which precedes every real row so
-- nothing is skipped. $4 = limit; the caller fetches limit+1 to detect a further
-- page. lower(billing_period) is bound to a real `b` first so the keyset compares
-- the same expression the ORDER BY sorts on.
SELECT * FROM (
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
  ), 0)::numeric AS total,
  (
    SELECT lower(issued.status_during)
      FROM invoice_status issued
     WHERE issued.invoice_id = invoice.id
       AND issued.status = 'issued'
       AND lower(issued.status_during) <= $1::date
     LIMIT 1
  ) AS "issued_at?",
  (
    SELECT lower(paid.status_during)
      FROM invoice_status paid
     WHERE paid.invoice_id = invoice.id
       AND paid.status = 'paid'
       AND lower(paid.status_during) <= $1::date
     LIMIT 1
  ) AS "paid_at?"
FROM invoice
JOIN invoice_subject ON invoice_subject.invoice_id = invoice.id
JOIN invoice_status ON invoice_status.invoice_id = invoice.id
                   AND invoice_status.status_during @> $1::date
) page
WHERE (page.billing_from, page.id) > ($2::date, $3::int)
ORDER BY page.billing_from, page.id
LIMIT $4::int;
