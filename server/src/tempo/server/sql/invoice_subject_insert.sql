-- invoice_subject_insert.sql — record an invoice's immutable subject (1:1 fact).
--
-- A plain INSERT (write pattern 1) into the 1:1 invoice_subject fact, keyed by the
-- minted invoice anchor id. The subject is set once at draft and never changed:
-- $1 = invoice_id, $2/$3 = the half-open [from, to) billing-month bounds, built
-- into a daterange in SQL. The invoice_subject_within_project PERIOD FK enforces
-- the billing month ⊂ the project's active run.
INSERT INTO invoice_subject (invoice_id, project_id, billing_period)
VALUES ($1, $2, daterange($3::date, $4::date, '[)'));
