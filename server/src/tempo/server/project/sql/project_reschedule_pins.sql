-- project_reschedule_pins.sql — reschedule guard counts for one project: how many
-- run rows it has, and how many timesheet / invoice_subject rows pin its schedule.
-- $1 = project_id.
SELECT
  (SELECT count(*) FROM project_run WHERE project_id = $1)::int AS runs,
  (SELECT count(*) FROM timesheet WHERE project_id = $1)::int AS timesheets,
  (SELECT count(*) FROM invoice_subject WHERE project_id = $1)::int AS invoices;
