-- rate_card_for_portion_of.sql — surgical charge-rate edit.
--
-- Bump a level's day_rate for PART of its validity via FOR PORTION OF: PG splits
-- the covering rate_card row, changing only the [$1, $2) sub-period and carving
-- off the unchanged before/after remainder as their own rows. The boundaries are
-- plain `date` params cast in SQL (ADR-011); $3 is the new rate, $4 the level.
--
-- PG reports `UPDATE 1` even when it produces extra rows, so never infer a split
-- from the affected-row count — read the rows back instead.
UPDATE rate_card
   FOR PORTION OF valid_at FROM $1::date TO $2::date
   SET day_rate = $3
 WHERE level = $4;
