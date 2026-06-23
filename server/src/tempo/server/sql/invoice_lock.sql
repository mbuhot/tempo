-- invoice_lock.sql — take a row lock on the invoice anchor before reading its
-- status, so a status transition's read-modify-write is serialized per invoice.
--
-- Under READ COMMITTED two concurrent transitions can otherwise both read the same
-- pre-status and both commit (issue #2: double-pay). Locking the anchor with
-- `FOR UPDATE` makes the second transaction block until the first commits, then
-- re-read the now-changed status and fail the transition guard. $1 = invoice_id.
SELECT id FROM invoice WHERE id = $1 FOR UPDATE;
