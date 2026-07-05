-- holiday_region_exists.sql — whether ($1, $2) names a known region. $1 country, $2 region.
SELECT EXISTS (SELECT 1 FROM holiday_region WHERE country = $1 AND region = $2) AS known;
