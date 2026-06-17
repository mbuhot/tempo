-- invoice_status_close.sql — cap an invoice's current status at $2.
--
-- Close half of a status transition: `DELETE … FOR PORTION OF status_during
-- FROM $2 TO NULL` removes the [$2, ∞) tail of the open status, capping the
-- spanning row to [row.lower, $2) (Postgres re-inserts the before-leftover).
-- The caller then runs invoice_status_open to start the new status at $2.
-- Keyed to the invoice — the open span is the only one covering $2.
--
-- $1 = invoice_id, $2 = transition day (scalar date, cast in SQL).
DELETE FROM invoice_status
   FOR PORTION OF status_during FROM $2::date TO NULL
 WHERE invoice_id = $1;
