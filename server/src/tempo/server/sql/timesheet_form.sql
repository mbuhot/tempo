-- timesheet_form.sql — my allocations as of a day, with any hours already logged
-- (ARCHITECTURE.md §5). Only projects the engineer is actually on as of $2::date
-- are returned; on a day covered by leave the result is empty, so the form offers
-- nothing (leave takes precedence over an allocation). A project the engineer has
-- rolled off is simply absent — the negative case the PERIOD FK also backstops on
-- write.
--
-- $1 = engineer_id, $2 = the day. `hours` is COALESCEd to 0 for an un-logged
-- project so the form always has a value to render. Ranges are decomposed to
-- plain `date`s at the boundary (ADR-011): valid_from/valid_to are the
-- allocation engagement window.
SELECT
  pr.id AS project_id,
  pr.name AS project,
  al.fraction,
  COALESCE(ts.hours, 0) AS hours,
  lower(al.valid_at) AS valid_from,
  upper(al.valid_at) AS valid_to
FROM allocation al
JOIN project pr ON pr.id = al.project_id AND pr.valid_at @> $2::date
LEFT JOIN timesheet ts
  ON ts.engineer_id = al.engineer_id
 AND ts.project_id  = al.project_id
 AND ts.work_day @> $2::date
WHERE al.engineer_id = $1 AND al.valid_at @> $2::date
  AND NOT EXISTS (
    SELECT 1 FROM leave lv
    WHERE lv.engineer_id = $1 AND lv.valid_at @> $2::date
  )
ORDER BY pr.name;
