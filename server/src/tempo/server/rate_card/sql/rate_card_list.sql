-- rate_card_list.sql — the current charge rate per level as of $1 (GET
-- /api/settings?as_of=$1; the rate-card table on the Settings page; FR-ST1). One
-- row per level whose rate_card span covers $1: level + day_rate, ordered by level.
-- A level with no rate covering $1 is simply absent. Param: $1 = the as-of date.
SELECT
  rate_card.level,
  rate_card.day_rate::text AS day_rate
FROM rate_card
WHERE rate_card.effective_during @> $1::date
ORDER BY rate_card.level;
