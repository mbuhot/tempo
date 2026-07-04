//// This module contains the code to run the sql queries defined in
//// `./src/tempo/server/schedule/sql`.
//// > 🐿️ This module was generated automatically using v4.7.0 of
//// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
////

import gleam/dynamic/decode
import gleam/time/calendar.{type Date}
import pog

/// A row you get from running the `schedule_capability_gaps` query
/// defined in `./src/tempo/server/schedule/sql/schedule_capability_gaps.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type ScheduleCapabilityGapsRow {
  ScheduleCapabilityGapsRow(
    project_id: Int,
    capability_id: Int,
    name: String,
    target_level: Int,
    week: Date,
    quantity: Float,
    covered: Float,
    best: Float,
  )
}

/// schedule_capability_gaps.sql — capability requirement lines per project per week:
/// covered = sum of allocated fractions of engineers whose weighted-average rollup
/// (unassessed skills count 0) meets the target level that week and who are off
/// leave; best = the highest qualifying-or-not rollup on the team that week, for
/// the inspector's coverage chart. $1 = as_of.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn schedule_capability_gaps(
  db: pog.Connection,
  arg_1: Date,
) -> Result(pog.Returned(ScheduleCapabilityGapsRow), pog.QueryError) {
  let decoder = {
    use project_id <- decode.field(0, decode.int)
    use capability_id <- decode.field(1, decode.int)
    use name <- decode.field(2, decode.string)
    use target_level <- decode.field(3, decode.int)
    use week <- decode.field(4, pog.calendar_date_decoder())
    use quantity <- decode.field(5, pog.numeric_decoder())
    use covered <- decode.field(6, pog.numeric_decoder())
    use best <- decode.field(7, pog.numeric_decoder())
    decode.success(ScheduleCapabilityGapsRow(
      project_id:,
      capability_id:,
      name:,
      target_level:,
      week:,
      quantity:,
      covered:,
      best:,
    ))
  }

  "-- schedule_capability_gaps.sql — capability requirement lines per project per week:
-- covered = sum of allocated fractions of engineers whose weighted-average rollup
-- (unassessed skills count 0) meets the target level that week and who are off
-- leave; best = the highest qualifying-or-not rollup on the team that week, for
-- the inspector's coverage chart. $1 = as_of.
WITH weeks AS (
  SELECT week_start::date AS week
  FROM generate_series(
    date_trunc('week', $1::date),
    date_trunc('week', $1::date) + interval '11 weeks',
    interval '1 week') AS week_start
),
demand AS (
  SELECT project_capability.project_id, project_capability.capability_id,
         project_capability.target_level, project_capability.quantity, weeks.week
  FROM weeks
  JOIN project_capability ON project_capability.required_during @> weeks.week
),
staff AS (
  SELECT demand.project_id, demand.capability_id, demand.target_level, demand.week,
         allocation.engineer_id, allocation.fraction,
         (leave.engineer_id IS NOT NULL) AS on_leave
  FROM demand
  JOIN allocation
    ON allocation.project_id = demand.project_id
   AND allocation.allocated_during @> demand.week
  LEFT JOIN leave
    ON leave.engineer_id = allocation.engineer_id
   AND leave.on_leave_during @> demand.week
),
proficiency AS (
  SELECT staff.project_id, staff.capability_id, staff.target_level, staff.week,
         staff.engineer_id, staff.fraction, staff.on_leave,
         (sum(coalesce(engineer_skill.level, 0) * capability_skill.weight)::numeric
           / sum(capability_skill.weight)::numeric) AS rollup
  FROM staff
  JOIN capability_skill
    ON capability_skill.capability_id = staff.capability_id
   AND capability_skill.mapped_during @> staff.week
  LEFT JOIN engineer_skill
    ON engineer_skill.skill_id = capability_skill.skill_id
   AND engineer_skill.engineer_id = staff.engineer_id
   AND engineer_skill.assessed_during @> staff.week
  GROUP BY staff.project_id, staff.capability_id, staff.target_level, staff.week,
           staff.engineer_id, staff.fraction, staff.on_leave
)
SELECT
  demand.project_id,
  demand.capability_id,
  coalesce(capability_profile.name, '') AS name,
  demand.target_level,
  demand.week,
  demand.quantity AS quantity,
  coalesce(
    sum(proficiency.fraction)
      FILTER (WHERE proficiency.rollup >= demand.target_level
                AND NOT proficiency.on_leave),
    0) AS covered,
  coalesce(max(proficiency.rollup), 0) AS best
FROM demand
JOIN capability_profile
  ON capability_profile.capability_id = demand.capability_id
 AND capability_profile.defined_during @> demand.week
LEFT JOIN proficiency
  ON proficiency.project_id = demand.project_id
 AND proficiency.capability_id = demand.capability_id
 AND proficiency.week = demand.week
GROUP BY demand.project_id, demand.capability_id, capability_profile.name,
         demand.target_level, demand.week, demand.quantity
ORDER BY demand.project_id, name, demand.week;
"
  |> pog.query
  |> pog.parameter(pog.calendar_date(arg_1))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `schedule_lanes` query
/// defined in `./src/tempo/server/schedule/sql/schedule_lanes.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type ScheduleLanesRow {
  ScheduleLanesRow(
    project_id: Int,
    engineer_id: Int,
    name: String,
    level: Int,
    week: Date,
    fraction: Float,
    on_leave: Bool,
  )
}

/// schedule_lanes.sql — one row per allocated engineer x week for every project in
/// the window: the fraction in force at the week start and whether leave covers it.
/// Lane level is as-of $1 (the label), coalesced to 0 when no role row covers it.
/// $1 = as_of.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn schedule_lanes(
  db: pog.Connection,
  arg_1: Date,
) -> Result(pog.Returned(ScheduleLanesRow), pog.QueryError) {
  let decoder = {
    use project_id <- decode.field(0, decode.int)
    use engineer_id <- decode.field(1, decode.int)
    use name <- decode.field(2, decode.string)
    use level <- decode.field(3, decode.int)
    use week <- decode.field(4, pog.calendar_date_decoder())
    use fraction <- decode.field(5, pog.numeric_decoder())
    use on_leave <- decode.field(6, decode.bool)
    decode.success(ScheduleLanesRow(
      project_id:,
      engineer_id:,
      name:,
      level:,
      week:,
      fraction:,
      on_leave:,
    ))
  }

  "-- schedule_lanes.sql — one row per allocated engineer x week for every project in
-- the window: the fraction in force at the week start and whether leave covers it.
-- Lane level is as-of $1 (the label), coalesced to 0 when no role row covers it.
-- $1 = as_of.
WITH weeks AS (
  SELECT week_start::date AS week
  FROM generate_series(
    date_trunc('week', $1::date),
    date_trunc('week', $1::date) + interval '11 weeks',
    interval '1 week') AS week_start
)
SELECT
  allocation.project_id,
  allocation.engineer_id,
  coalesce(engineer_current.name, '') AS name,
  coalesce(role_now.level, 0) AS level,
  weeks.week,
  allocation.fraction AS fraction,
  (leave.engineer_id IS NOT NULL) AS on_leave
FROM weeks
JOIN allocation ON allocation.allocated_during @> weeks.week
JOIN engineer_current ON engineer_current.id = allocation.engineer_id
LEFT JOIN engineer_role role_now
  ON role_now.engineer_id = allocation.engineer_id
 AND role_now.held_during @> $1::date
LEFT JOIN leave
  ON leave.engineer_id = allocation.engineer_id
 AND leave.on_leave_during @> weeks.week
ORDER BY allocation.project_id, name, weeks.week;
"
  |> pog.query
  |> pog.parameter(pog.calendar_date(arg_1))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `schedule_level_gaps` query
/// defined in `./src/tempo/server/schedule/sql/schedule_level_gaps.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type ScheduleLevelGapsRow {
  ScheduleLevelGapsRow(
    project_id: Int,
    level: Int,
    week: Date,
    quantity: Float,
    covered: Float,
  )
}

/// schedule_level_gaps.sql — level requirement lines per project per week with the
/// covered sum (allocated fractions of engineers at level >= required, off leave).
/// Gap arithmetic happens in the view: gap = greatest(0, quantity - covered).
/// $1 = as_of.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn schedule_level_gaps(
  db: pog.Connection,
  arg_1: Date,
) -> Result(pog.Returned(ScheduleLevelGapsRow), pog.QueryError) {
  let decoder = {
    use project_id <- decode.field(0, decode.int)
    use level <- decode.field(1, decode.int)
    use week <- decode.field(2, pog.calendar_date_decoder())
    use quantity <- decode.field(3, pog.numeric_decoder())
    use covered <- decode.field(4, pog.numeric_decoder())
    decode.success(ScheduleLevelGapsRow(
      project_id:,
      level:,
      week:,
      quantity:,
      covered:,
    ))
  }

  "-- schedule_level_gaps.sql — level requirement lines per project per week with the
-- covered sum (allocated fractions of engineers at level >= required, off leave).
-- Gap arithmetic happens in the view: gap = greatest(0, quantity - covered).
-- $1 = as_of.
WITH weeks AS (
  SELECT week_start::date AS week
  FROM generate_series(
    date_trunc('week', $1::date),
    date_trunc('week', $1::date) + interval '11 weeks',
    interval '1 week') AS week_start
)
SELECT
  requirement.project_id,
  requirement.level,
  weeks.week,
  requirement.quantity AS quantity,
  coalesce(
    sum(allocation.fraction)
      FILTER (WHERE role_week.level >= requirement.level
                AND leave.engineer_id IS NULL),
    0) AS covered
FROM weeks
JOIN project_requirement requirement ON requirement.required_during @> weeks.week
LEFT JOIN allocation
  ON allocation.project_id = requirement.project_id
 AND allocation.allocated_during @> weeks.week
LEFT JOIN engineer_role role_week
  ON role_week.engineer_id = allocation.engineer_id
 AND role_week.held_during @> weeks.week
LEFT JOIN leave
  ON leave.engineer_id = allocation.engineer_id
 AND leave.on_leave_during @> weeks.week
GROUP BY requirement.project_id, requirement.level, weeks.week, requirement.quantity
ORDER BY requirement.project_id, requirement.level, weeks.week;
"
  |> pog.query
  |> pog.parameter(pog.calendar_date(arg_1))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `schedule_projects` query
/// defined in `./src/tempo/server/schedule/sql/schedule_projects.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type ScheduleProjectsRow {
  ScheduleProjectsRow(
    project_id: Int,
    title: String,
    client: String,
    run_from: Date,
    run_to: Date,
  )
}

/// schedule_projects.sql — projects whose run overlaps the 12-week window opening
/// at the Monday of $1. Runs are bounded (contained in bounded contract terms),
/// so upper() is safe. $1 = as_of.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn schedule_projects(
  db: pog.Connection,
  arg_1: Date,
) -> Result(pog.Returned(ScheduleProjectsRow), pog.QueryError) {
  let decoder = {
    use project_id <- decode.field(0, decode.int)
    use title <- decode.field(1, decode.string)
    use client <- decode.field(2, decode.string)
    use run_from <- decode.field(3, pog.calendar_date_decoder())
    use run_to <- decode.field(4, pog.calendar_date_decoder())
    decode.success(ScheduleProjectsRow(
      project_id:,
      title:,
      client:,
      run_from:,
      run_to:,
    ))
  }

  "-- schedule_projects.sql — projects whose run overlaps the 12-week window opening
-- at the Monday of $1. Runs are bounded (contained in bounded contract terms),
-- so upper() is safe. $1 = as_of.
SELECT
  project_run.project_id,
  coalesce(project_current.title, '') AS title,
  coalesce(client_current.name, '') AS client,
  lower(project_run.active_during) AS run_from,
  upper(project_run.active_during) AS run_to
FROM project_run
JOIN contract_terms
  ON contract_terms.contract_id = project_run.contract_id
 AND contract_terms.term @> lower(project_run.active_during)
JOIN client_current ON client_current.id = contract_terms.client_id
JOIN project_current ON project_current.id = project_run.project_id
WHERE project_run.active_during
   && daterange(date_trunc('week', $1::date)::date,
                (date_trunc('week', $1::date) + interval '12 weeks')::date, '[)')
ORDER BY title;
"
  |> pog.query
  |> pog.parameter(pog.calendar_date(arg_1))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `schedule_totals` query
/// defined in `./src/tempo/server/schedule/sql/schedule_totals.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type ScheduleTotalsRow {
  ScheduleTotalsRow(engineer_id: Int, week: Date, total: Float)
}

/// schedule_totals.sql — each engineer's total allocated fraction per week across
/// ALL projects, for the over-allocation flag (> 1.0). $1 = as_of.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn schedule_totals(
  db: pog.Connection,
  arg_1: Date,
) -> Result(pog.Returned(ScheduleTotalsRow), pog.QueryError) {
  let decoder = {
    use engineer_id <- decode.field(0, decode.int)
    use week <- decode.field(1, pog.calendar_date_decoder())
    use total <- decode.field(2, pog.numeric_decoder())
    decode.success(ScheduleTotalsRow(engineer_id:, week:, total:))
  }

  "-- schedule_totals.sql — each engineer's total allocated fraction per week across
-- ALL projects, for the over-allocation flag (> 1.0). $1 = as_of.
WITH weeks AS (
  SELECT week_start::date AS week
  FROM generate_series(
    date_trunc('week', $1::date),
    date_trunc('week', $1::date) + interval '11 weeks',
    interval '1 week') AS week_start
)
SELECT allocation.engineer_id, weeks.week, sum(allocation.fraction) AS total
FROM weeks
JOIN allocation ON allocation.allocated_during @> weeks.week
GROUP BY allocation.engineer_id, weeks.week
ORDER BY allocation.engineer_id, weeks.week;
"
  |> pog.query
  |> pog.parameter(pog.calendar_date(arg_1))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `schedule_weeks` query
/// defined in `./src/tempo/server/schedule/sql/schedule_weeks.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type ScheduleWeeksRow {
  ScheduleWeeksRow(week: Date)
}

/// schedule_weeks.sql — the 12 week-start Mondays opening at the Monday of $1.
/// $1 = as_of.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn schedule_weeks(
  db: pog.Connection,
  arg_1: Date,
) -> Result(pog.Returned(ScheduleWeeksRow), pog.QueryError) {
  let decoder = {
    use week <- decode.field(0, pog.calendar_date_decoder())
    decode.success(ScheduleWeeksRow(week:))
  }

  "-- schedule_weeks.sql — the 12 week-start Mondays opening at the Monday of $1.
-- $1 = as_of.
SELECT week_start::date AS week
FROM generate_series(
  date_trunc('week', $1::date),
  date_trunc('week', $1::date) + interval '11 weeks',
  interval '1 week') AS week_start
ORDER BY week;
"
  |> pog.query
  |> pog.parameter(pog.calendar_date(arg_1))
  |> pog.returning(decoder)
  |> pog.execute(db)
}
