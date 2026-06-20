-- invoice_subject_insert.sql — the immutable 1:1 invoice subject (project + billing
-- month), contained by the project run. Last param is the audit_id. $1 = invoice_id,
-- $2 = project_id, $3 = billing_from, $4 = billing_to.
INSERT INTO invoice_subject (invoice_id, project_id, billing_period, audit_id)
VALUES ($1, $2, daterange($3::date, $4::date, '[)'), $5);
