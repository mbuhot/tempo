-- invoice_status_current.sql — the status of an invoice AS OF $2.
--
-- The transition guard: reads the single status row covering $2 via `@>` so the
-- command can validate the from-state before opening a new status. $1 is the
-- invoice_id, $2 the as-of date.
SELECT status
  FROM invoice_status
 WHERE invoice_id = $1
   AND status_during @> $2::date;
