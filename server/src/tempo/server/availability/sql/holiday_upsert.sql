-- holiday_upsert.sql — import one holiday row. $1 country, $2 region ('' = nationwide),
-- $3 date, $4 name, $5 audit_id. Re-import refreshes the name.
INSERT INTO holiday (country, region, holiday_on, name, audit_id)
VALUES ($1, $2, $3::date, $4, $5)
ON CONFLICT (country, region, holiday_on)
DO UPDATE SET name = EXCLUDED.name, audit_id = EXCLUDED.audit_id;
