-- leave_check.sql — the take_leave guard input for a [valid_from, valid_to) leave:
-- `available` is the balance on return (accrued − taken as of valid_to, the new
-- leave not yet recorded), `requested` the calendar days (valid_to − valid_from), and
-- `policied` whether the kind has any policy (false ⇒ unlimited, no guard). The
-- handler rejects when policied AND available < requested.
-- $1 = engineer_id, $2 = kind, $3 = valid_from, $4 = valid_to.
SELECT
  EXISTS (SELECT 1 FROM leave_policy WHERE kind = $2) AS policied,
  (accrued_leave($1, $2, $4::date) - taken_leave($1, $2, $4::date))::numeric AS available,
  ($4::date - $3::date)::numeric AS requested;
