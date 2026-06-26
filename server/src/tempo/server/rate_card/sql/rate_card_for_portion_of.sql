-- rate_card_for_portion_of.sql — surgical charge-rate edit. FOR PORTION OF splits the
-- covering rate_card row, setting day_rate + audit_id only on [$1, $2) and carving
-- off the unchanged before/after remainders keeping their original audit_id.
-- $1 = from, $2 = to, $3 = new rate (exact decimal text, cast to numeric),
-- $4 = level, $5 = audit_id.
--
-- PG reports `UPDATE 1` even when it produces extra rows, so never infer a split
-- from the affected-row count — read the rows back instead.
UPDATE rate_card
   FOR PORTION OF effective_during FROM $1::date TO $2::date
   SET day_rate = $3::text::numeric, audit_id = $5
 WHERE level = $4;
