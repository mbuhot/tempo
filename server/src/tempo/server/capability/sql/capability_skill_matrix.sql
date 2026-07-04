-- capability_skill_matrix.sql — every (capability, skill, weight) mapping in
-- force as-of $1, for the taxonomy snapshot's composition matrix. $1 = as_of date.
SELECT capability_id, skill_id, weight
  FROM capability_skill
 WHERE mapped_during @> $1::date
 ORDER BY capability_id, skill_id;
