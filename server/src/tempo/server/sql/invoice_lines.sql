-- invoice_lines.sql — an invoice's snapshot lines for the detail read model
-- (GET /api/invoices/:id). The plain rows computed when the invoice was drafted
-- (invoice_line), joined to the engineer name; not a recomputation (PRD §8: an
-- issued invoice's lines do not change).
--
-- Param: $1 = invoice_id. Ordered as the billing query emitted them (engineer,
-- level) so a promotion's two lines stay adjacent and the wire order is
-- deterministic for the client and tests.
SELECT
  coalesce(engineer.name, '') AS engineer,
  invoice_line.level,
  invoice_line.day_rate::numeric AS day_rate,
  invoice_line.days::numeric AS days,
  invoice_line.amount::numeric AS amount
FROM invoice_line
JOIN engineer_current engineer ON engineer.id = invoice_line.engineer_id
WHERE invoice_line.invoice_id = $1
ORDER BY engineer.name, invoice_line.level;
