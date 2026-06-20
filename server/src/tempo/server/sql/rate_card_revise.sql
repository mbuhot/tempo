-- rate_card_revise.sql — change a level's day_rate from $1 onward (Change). FOR
-- PORTION OF re-rates [$1, ∞) of the covering row, setting day_rate + audit_id; PG
-- carves off the unchanged [start, $1) remainder keeping its original audit_id. The
-- `@>` guard leaves a scheduled future version untouched. $1 = effective,
-- $2 = new rate, $3 = level, $4 = audit_id.
--
-- PG reports `UPDATE 1` even when it produces an extra remainder row, so never
-- infer a split from the affected-row count — read the rows back instead.
UPDATE rate_card
   FOR PORTION OF effective_during FROM $1::date TO NULL
   SET day_rate = $2, audit_id = $4
 WHERE level = $3
   AND effective_during @> $1::date;
