-- leave_balances.sql — each engineer employed as of $1 with their annual and sick
-- leave balance (accrued − taken, rounded to one day) on that date, for the board
-- readout; it recomputes as the board's date moves. $1 = the as-of date.
--
-- engineer_id is emitted alongside the name so the people-roster read model can
-- join the annual balance to people_list.sql rows by id (the board readout keys by
-- name; /api/people keys by id).
SELECT
  engineer.id AS engineer_id,
  coalesce(engineer_current.name, '') AS engineer,
  round(accrued_leave(engineer.id, 'annual', $1::date)
        - taken_leave(engineer.id, 'annual', $1::date), 1)::numeric AS annual,
  round(accrued_leave(engineer.id, 'sick', $1::date)
        - taken_leave(engineer.id, 'sick', $1::date), 1)::numeric AS sick
FROM engineer
JOIN engineer_current ON engineer_current.id = engineer.id
WHERE EXISTS (
  SELECT 1 FROM employment
  WHERE employment.engineer_id = engineer.id
    AND employment.employed_during @> $1::date
)
ORDER BY engineer;
