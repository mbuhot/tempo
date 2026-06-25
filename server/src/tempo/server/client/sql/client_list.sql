-- client_list.sql — the clients-directory read model (GET /api/clients?as_of=$1;
-- mirrors project_list's as-of existence). One row per client that has COME INTO
-- EXISTENCE by $1 — i.e. has a contract whose term STARTS on or before $1: name, the
-- earliest contract start (since), the count of distinct projects ever run for the
-- client, and whether any contract covers $1 (active). Param: $1 = the as-of date.
--
-- EXISTENCE. A client whose first contract starts AFTER $1 is absent, not rendered as
-- 'ended' (the WHERE EXISTS lower(term) <= $1) — the timeline-scrub mirror of
-- project_list (#19). A client that HAS started but whose contracts have all ended by
-- $1 still lists, with active=false → the 'ended' pill, which is now shown only for a
-- genuinely-ended client.
--
-- name from the client_current latest-read view (INNER join — every seeded client has
-- a profile). `since` is min(lower(term)) over the client's contracts (always <= $1
-- for a listed client). The `"since?"` alias forces the generated column to
-- Option(Date) (the schema does not guarantee >=1 contract), matching the shared
-- ClientListRow.since. `active` is a correlated bool_or(term @> $1) coalesced to
-- false. The project count is a correlated count of distinct project ids reachable
-- through the client's contracts' runs. Ordered by name for a stable directory.
--
-- Keyset pagination (#12). Stable total order is (name, client_id) — the display
-- order plus the unique id tiebreaker. The cursor names the last row returned:
-- $2 = its name, $3 = its id; a row is on the NEXT page when (name, id) sorts
-- strictly after it. The first page passes the sentinel ('', 0), which precedes
-- every real row. $4 = limit; the caller fetches limit+1 to detect a further page.
SELECT * FROM (
SELECT
  client.id AS client_id,
  coalesce(client_current.name, '') AS name,
  (
    SELECT min(lower(contract_terms.term))
      FROM contract_terms
     WHERE contract_terms.client_id = client.id
  ) AS "since?",
  (
    SELECT count(DISTINCT project_run.project_id)
      FROM contract_terms
      JOIN project_run ON project_run.contract_id = contract_terms.contract_id
     WHERE contract_terms.client_id = client.id
  )::int AS project_count,
  coalesce((
    SELECT bool_or(contract_terms.term @> $1::date)
      FROM contract_terms
     WHERE contract_terms.client_id = client.id
  ), false) AS active
FROM client
JOIN client_current ON client_current.id = client.id
WHERE EXISTS (
  SELECT 1
    FROM contract_terms
   WHERE contract_terms.client_id = client.id
     AND lower(contract_terms.term) <= $1::date
)
) page
WHERE (page.name, page.client_id) > ($2::text, $3::int)
ORDER BY page.name, page.client_id
LIMIT $4::int;
