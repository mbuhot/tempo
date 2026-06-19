-- invoice_create.sql — mint a new invoice identity (ID-ONLY anchor).
--
-- Step 1 of draft_invoice (anchor → subject → status → lines). `invoice.id` is
-- GENERATED ALWAYS AS IDENTITY, so the caller supplies nothing; RETURNING hands
-- back the minted id to thread into the invoice_subject, status, and line inserts.
-- The durable subject (project_id, billing_period) is written separately into the
-- 1:1 immutable invoice_subject fact by invoice_subject_insert.
INSERT INTO invoice DEFAULT VALUES
RETURNING id;
