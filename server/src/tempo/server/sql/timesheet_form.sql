-- timesheet_form.sql — my allocations as of a day, with any hours already logged.
-- Only projects the engineer is actually on as of $2::date
-- are returned; on a day covered by leave the result is empty, so the form offers
-- nothing (leave takes precedence over an allocation). A project the engineer has
-- rolled off is simply absent — the negative case the PERIOD FK also backstops on
-- write.
--
-- $1 = engineer_id, $2 = the day. `hours` is COALESCEd to 0 for an un-logged
-- project so the form always has a value to render. Ranges are decomposed to
-- plain `date`s at the boundary: valid_from/valid_to are the allocation
-- engagement window.
SELECT
  project.id AS project_id,
  project.name AS project,
  allocation.fraction,
  COALESCE(timesheet.hours, 0) AS hours,
  lower(allocation.allocated_during) AS valid_from,
  upper(allocation.allocated_during) AS valid_to
FROM allocation
JOIN project ON project.id = allocation.project_id AND project.active_during @> $2::date
LEFT JOIN timesheet
  ON timesheet.engineer_id = allocation.engineer_id
 AND timesheet.project_id  = allocation.project_id
 AND timesheet.work_day @> $2::date
WHERE allocation.engineer_id = $1 AND allocation.allocated_during @> $2::date
  AND NOT EXISTS (
    SELECT 1 FROM leave
    WHERE leave.engineer_id = $1 AND leave.on_leave_during @> $2::date
  )
ORDER BY project.name;
