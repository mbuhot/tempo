-- contract_rate_upsert.sql — record the contract's own day rate for a level from
-- $4 onward (delete-then-insert semantics, like engineer_role_upsert). The
-- temporal DELETE clips the row covering $4 to [start, $4) and removes any rows
-- that start at or after $4, then the INSERT opens a new row bounded by the
-- covering contract_terms row's own end — clipping the "open-ended from $4
-- onward" Change to the signed term keeps the contract_rate_within_term PERIOD FK
-- satisfiable while preserving open-ended-within-the-term semantics.
-- $1 = contract_id, $2 = level, $3 = new rate (exact decimal text, cast to
-- numeric), $4 = effective, $5 = audit_id.
--
-- With no signed term covering $4, the INSERT ... SELECT matches nothing and
-- RETURNING yields zero rows; the repository rejects that (NoSuchVersion) rather
-- than journalling a silent no-op.
WITH term AS (
  SELECT upper(term) AS term_end
  FROM contract_terms
  WHERE contract_id = $1 AND term @> $4::date
),
deleted AS (
  DELETE FROM contract_rate
    FOR PORTION OF effective_during FROM $4::date TO NULL
  WHERE contract_id = $1 AND level = $2
)
INSERT INTO contract_rate (contract_id, level, day_rate, effective_during, audit_id)
SELECT $1, $2, $3::text::numeric, daterange($4::date, term.term_end, '[)'), $5
FROM term
RETURNING contract_id;
