-- project_run_during.sql — confirm a project's run (existence/contract window)
-- covers a period; one row per run whose active_during contains [from, to).
-- Selects only NOT-NULL columns so an open-ended run (NULL upper bound) decodes
-- cleanly — the guard cares only that a row exists.
select
	project_id,
	contract_id
from project_run
where project_id = $1
	and (active_during @> daterange($2::date, $3::date, '[)'))
