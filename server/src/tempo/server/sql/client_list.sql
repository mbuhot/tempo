-- client_list.sql — the clients-directory read model (GET /api/clients?as_of=$1).
-- One row per client: name, the earliest contract start (since), the count of
-- distinct projects ever run for the client, and whether any contract covers $1
-- (active). Param: $1 = the as-of date (drives the active flag only; the identity
-- is durable).
--
-- name from the client_current latest-read view (INNER join — every seeded client
-- has a profile). `since` is min(lower(term)) over the client's contracts — NULL for
-- a contractless client (the schema does not guarantee >=1). The seed has no
-- contractless client, so Squirrel would infer a non-null Date off the road and
-- decode-fail the first contractless client; the `"since?"` alias forces the
-- generated column to Option(Date), matching the shared ClientListRow.since. `active`
-- is a correlated bool_or(term @> $1) coalesced to false (contractless or no covering
-- term). The project count is a correlated count of distinct project ids reachable
-- through the client's contracts' runs. Ordered by name for a stable directory.
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
ORDER BY name;
