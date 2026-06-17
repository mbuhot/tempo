-- invoice_status_open.sql — open a status span for an invoice from $3 onward.
--
-- A plain INSERT (write pattern 1) starting an open-ended [$3, ∞) status
-- period. Used both to seed the initial status and, after invoice_status_close
-- caps the prior one, to open the new status during a transition. $1 is the
-- invoice_id, $2 the status, $3 the effective date.
INSERT INTO invoice_status (invoice_id, status, status_during)
VALUES ($1, $2, daterange($3::date, NULL, '[)'));
