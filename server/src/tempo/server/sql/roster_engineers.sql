-- roster_engineers.sql — engineers EMPLOYED as-of the date ($1::date).
--
-- The engineer-directory slice the operations console offers as a name <select>:
-- only engineers whose employment window covers the slider's as-of date, so the
-- console can never name an engineer who is not on the books on that date. One
-- row per engineer (employment has at most one row covering a date), id + name,
-- ordered by name for a stable, alphabetised dropdown.
SELECT e.id, e.name
FROM engineer e
JOIN employment emp
  ON emp.engineer_id = e.id AND emp.employed_during @> $1::date
ORDER BY e.name;
