-- engineer_employment_during.sql — confirm an engineer is employed (with a role
-- and contact on file) across a period; one row per role version overlapping it.
-- Selects only NOT-NULL columns so an open-ended employment (NULL upper bound)
-- decodes cleanly — the guard cares only that a row exists.
select
	engineer_id,
	name,
	level
from engineer
join employment on (id = engineer_id)
join engineer_contact using (engineer_id)
join engineer_role using (engineer_id)
where engineer.id = $1
	and (employed_during @> daterange($2::date, $3::date, '[)'))
	and engineer_contact.recorded_during @> $3::date
	and engineer_role.held_during && daterange($2::date, $3::date, '[)')
