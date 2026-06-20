-- leave_balance.sql — an engineer's leave balance for a kind as of a date: days
-- accrued (employment ∩ role ∩ leave_policy[kind, level], leap-aware) minus days
-- taken, both up to as_of. `policied` is false when the kind has no policy at all —
-- then it is unlimited and the take_leave guard does not apply. The balance is a
-- pure calculation at any past or future date; nothing is stored.
-- $1 = engineer_id, $2 = kind, $3 = as_of date.
SELECT
  EXISTS (SELECT 1 FROM leave_policy WHERE kind = $2) AS policied,
  (accrued_leave($1, $2, $3::date) - taken_leave($1, $2, $3::date))::numeric AS balance;
