-- invoice_create.sql — open an invoice for a project's billing period.
--
-- A plain INSERT (write pattern 1). The id is auto-generated and returned. The
-- billing_period is a daterange built from the half-open [$2, $3) month bounds;
-- $1 is the project_id.
INSERT INTO invoice (project_id, billing_period)
VALUES ($1, daterange($2::date, $3::date, '[)'))
RETURNING id;
