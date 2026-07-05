-- holidays_upcoming.sql — all holidays on/after $1 with their region names. $1 as_of.
SELECT h.country AS country, h.region AS region, r.name AS region_name,
       h.holiday_on AS holiday_on, h.name AS name
FROM holiday h
JOIN holiday_region r ON r.country = h.country AND r.region = h.region
WHERE h.holiday_on >= $1::date
ORDER BY h.holiday_on, h.country, h.region;
