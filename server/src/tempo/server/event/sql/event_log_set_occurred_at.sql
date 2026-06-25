-- event_log_set_occurred_at.sql — backdate one journal row's occurred_at to a
-- simulated entry date. Used ONLY by the demo seed (tempo/seed_financials) to give
-- the journal a realistic timeline: each operation recorded when it would naturally
-- have been entered (timesheets at the end of their week, invoices and payroll at
-- month end) rather than all at the instant the seed ran. Production records
-- occurred_at as the real wall clock (event_log_append.sql) and never calls this.
--
-- $1 = event id, $2 = the date to record it as (set to midnight of that day).
UPDATE event_log SET occurred_at = $2::date WHERE id = $1;
