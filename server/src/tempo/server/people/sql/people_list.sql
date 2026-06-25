-- people_list.sql — the people-roster read model (GET /api/people?as_of=$1). One
-- row per EMPLOYED engineer as of $1, carrying everything the roster table needs
-- that the org board cannot supply: the engineer_id and email (BoardRow has
-- neither), the as-of level and resolved day_rate (present for EVERY employed
-- engineer, not just allocated ones — board day_rate lives only on engaged rows),
-- the summed allocation fraction across all the engineer's projects, the covering
-- leave kind if any, and a comma-joined list of the project titles the engineer is
-- allocated to on the date.
--
-- Param: $1 = the as-of date.
--
-- Identity + level + rate. employment(@>$1) anchors the employed set; the name and
-- email come from the engineer_current latest-read view; the as-of level from
-- engineer_role(@>$1); the charge rate from rate_card(level, effective_during @>$1)
-- (the same two-hop role x rate_card join the board uses). These are INNER joins —
-- an employed engineer always has a role and a rate, so day_rate is non-null.
--
-- Allocation rollup. A correlated LATERAL aggregates the engineer's allocations
-- covering $1 (joined to project_current for the titles): SUM(fraction) coalesced
-- to 0 for a bench/leave engineer, and string_agg of distinct project titles. The
-- titles are joined in one comma-separated string (the domain layer splits it back
-- into a list); an engineer with no covering allocation gets '' which the domain
-- reads as the empty project list.
--
-- Leave. A LEFT JOIN LATERAL returns the covering leave fact's kind (NULL when not
-- on leave — the lateral join makes Squirrel infer leave_kind as Option(String)
-- rather than a non-null String that would decode-fail off the road); the domain
-- layer collapses status to RosterOnLeave(kind) when present, else
-- RosterOnProjects(titles) when allocated, else RosterUnassigned. The annual leave
-- balance is NOT joined here — the domain joins leave_balances.sql by engineer_id.
--
-- Keyset pagination (#12). Stable total order is (name, engineer_id) — the display
-- order plus the unique id tiebreaker. The cursor names the last row returned:
-- $2 = its name, $3 = its id; a row is on the NEXT page when (name, id) sorts
-- strictly after it. The first page passes the sentinel ('', 0), which precedes
-- every real row. $4 = limit; the caller fetches limit+1 to detect a further page.
SELECT * FROM (
SELECT
  engineer.id AS engineer_id,
  coalesce(engineer_current.name, '') AS name,
  coalesce(engineer_current.email, '') AS email,
  engineer_role.level,
  rate_card.day_rate,
  coalesce(alloc.allocated_fraction, 0)::numeric AS allocated_fraction,
  coalesce(alloc.projects, '') AS projects,
  on_leave.kind AS leave_kind
FROM employment
JOIN engineer ON engineer.id = employment.engineer_id
JOIN engineer_current ON engineer_current.id = engineer.id
JOIN engineer_role ON engineer_role.engineer_id = engineer.id
                  AND engineer_role.held_during @> $1::date
JOIN rate_card ON rate_card.level = engineer_role.level
              AND rate_card.effective_during @> $1::date
LEFT JOIN LATERAL (
  SELECT leave.kind FROM leave
   WHERE leave.engineer_id = engineer.id
     AND leave.on_leave_during @> $1::date
   LIMIT 1
) on_leave ON true
LEFT JOIN LATERAL (
  SELECT sum(allocation.fraction) AS allocated_fraction,
         string_agg(DISTINCT coalesce(project_current.title, ''), ', '
                    ORDER BY coalesce(project_current.title, '')) AS projects
    FROM allocation
    JOIN project_run ON project_run.project_id = allocation.project_id
                    AND project_run.active_during @> $1::date
    JOIN project_current ON project_current.id = allocation.project_id
   WHERE allocation.engineer_id = engineer.id
     AND allocation.allocated_during @> $1::date
) alloc ON true
WHERE employment.employed_during @> $1::date
) page
WHERE (page.name, page.engineer_id) > ($2::text, $3::int)
ORDER BY page.name, page.engineer_id
LIMIT $4::int;
