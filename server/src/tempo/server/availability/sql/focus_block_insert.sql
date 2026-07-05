-- focus_block_insert.sql — add a focus block. $1 engineer_id, $2 date, $3 starts (HH:MM),
-- $4 duration_minutes, $5 timezone, $6 title, $7 audit_id.
INSERT INTO focus_block (engineer_id, busy_at, title, audit_id)
VALUES ($1,
  tstzrange(
    (($2::text || ' ' || $3::text)::timestamp AT TIME ZONE $5),
    (($2::text || ' ' || $3::text)::timestamp AT TIME ZONE $5) + ($4::text || ' minutes')::interval,
    '[)'),
  $6, $7);
