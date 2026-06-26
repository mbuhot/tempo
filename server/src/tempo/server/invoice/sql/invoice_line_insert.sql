-- invoice_line_insert.sql — one snapshotted billing line. Last param is the
-- audit_id. $1 = invoice_id, $2 = engineer_id, $3 = level, $4 = day_rate (exact
-- decimal text), $5 = days, $6 = amount (exact decimal text).
INSERT INTO invoice_line (invoice_id, engineer_id, level, day_rate, days, amount, audit_id)
VALUES ($1, $2, $3, $4::text::numeric, $5, $6::text::numeric, $7);
