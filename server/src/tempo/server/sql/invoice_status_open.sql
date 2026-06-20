-- invoice_status_open.sql — open a status span for an invoice from $3 onward. Last
-- param is the audit_id. $1 = invoice_id, $2 = status, $3 = from.
INSERT INTO invoice_status (invoice_id, status, status_during, audit_id)
VALUES ($1, $2, daterange($3::date, NULL, '[)'), $4);
