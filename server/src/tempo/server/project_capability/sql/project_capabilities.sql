-- project_capabilities.sql — one project's capability-requirement lines (demand)
-- as-of $2, for the project-detail Capability coverage tab. Params: $1 =
-- project_id, $2 = as-of date.
--
-- Joined through capability_profile as-of $2 for the capability's display name.
-- Range column decomposed via the lower/coalesce(upper)/upper_inf trio: a
-- requirement can be open-ended ([start, ∞)), so upper(required_during) is NULL —
-- valid_to coalesces to valid_from so the column stays a non-null date the
-- boundary can decode, and `ongoing` reports the open-endedness. Ordered by
-- capability name for a stable list.
SELECT
  project_capability.capability_id,
  capability_profile.name,
  project_capability.target_level,
  project_capability.quantity,
  lower(project_capability.required_during) AS valid_from,
  coalesce(upper(project_capability.required_during), lower(project_capability.required_during))
    AS valid_to,
  upper_inf(project_capability.required_during) AS ongoing
FROM project_capability
JOIN capability_profile
  ON capability_profile.capability_id = project_capability.capability_id
 AND capability_profile.defined_during @> $2::date
WHERE project_capability.project_id = $1
  AND project_capability.required_during @> $2::date
ORDER BY capability_profile.name;
