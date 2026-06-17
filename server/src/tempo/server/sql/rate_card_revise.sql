-- rate_card_revise.sql — change a level's day_rate from $1 onward.
--
-- CHANGE write: re-rate the version of a level in effect on $1 for the open
-- span [$1, ∞) via FOR PORTION OF. The `@>` guard confines the update to the
-- single rate_card row covering $1, so a separately-scheduled future version of
-- the same level stays untouched; PG carves off the unchanged [start, $1)
-- remainder as its own row. $1 is the effective date, $2 the new rate, $3 the
-- level.
--
-- PG reports `UPDATE 1` even when it produces an extra remainder row, so never
-- infer a split from the affected-row count — read the rows back instead.
UPDATE rate_card
   FOR PORTION OF effective_during FROM $1::date TO NULL
   SET day_rate = $2
 WHERE level = $3
   AND effective_during @> $1::date;
