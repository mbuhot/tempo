-- roster_engineers.sql — engineers EMPLOYED as-of the date ($1::date).
--
-- The engineer-directory slice the operations console offers as a name <select>:
-- only engineers whose employment window covers the slider's as-of date, so the
-- console can never name an engineer who is not on the books on that date. One
-- row per engineer (employment has at most one row covering a date), id + name,
-- ordered by name for a stable, alphabetised dropdown.
--
-- The id comes from the `engineer` ANCHOR (provably NOT NULL); the NAME, which
-- left the anchor for the edit-grouped contact fact, is read through the
-- `engineer_current` view (latest contact per engineer). The INNER JOIN means an
-- engineer with no contact row is omitted (every seeded/onboarded engineer has
-- one). coalesce keeps the name column NOT NULL through the view boundary; it is
-- never actually null (the join is on a NOT NULL contact column).
SELECT e.id, coalesce(ec.name, '') AS name
FROM engineer e
JOIN employment emp
  ON emp.engineer_id = e.id AND emp.employed_during @> $1::date
JOIN engineer_current ec ON ec.id = e.id
ORDER BY name;
