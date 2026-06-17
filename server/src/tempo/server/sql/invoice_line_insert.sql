-- invoice_line_insert.sql — append one billed line to an invoice.
--
-- A plain INSERT (write pattern 1). The line is pre-computed by the command: the
-- day_rate is resolved from rate_card for the engineer's level AS OF the
-- contract term's lower bound (FR-F2), not the invoice month. $1 = invoice_id,
-- $2 = engineer_id, $3 = level, $4 = day_rate, $5 = days, $6 = amount.
INSERT INTO invoice_line (invoice_id, engineer_id, level, day_rate, days, amount)
VALUES ($1, $2, $3, $4, $5, $6);
