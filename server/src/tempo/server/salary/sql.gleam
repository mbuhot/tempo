//// This module contains the code to run the sql queries defined in
//// `./src/tempo/server/salary/sql`.
//// > 🐿️ This module was generated automatically using v4.7.0 of
//// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
////

import gleam/dynamic/decode
import gleam/time/calendar.{type Date}
import pog

/// A row you get from running the `salary_list` query
/// defined in `./src/tempo/server/salary/sql/salary_list.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type SalaryListRow {
  SalaryListRow(level: Int, monthly_salary: String)
}

/// salary_list.sql — the current monthly salary per level as of $1 (GET
/// /api/settings?as_of=$1; the salaries table on the Settings page; FR-ST2). One row
/// per level whose salary span covers $1: level + monthly_salary, ordered by level. A
/// level with no salary covering $1 is simply absent. Param: $1 = the as-of date.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn salary_list(
  db: pog.Connection,
  arg_1: Date,
) -> Result(pog.Returned(SalaryListRow), pog.QueryError) {
  let decoder = {
    use level <- decode.field(0, decode.int)
    use monthly_salary <- decode.field(1, decode.string)
    decode.success(SalaryListRow(level:, monthly_salary:))
  }

  "-- salary_list.sql — the current monthly salary per level as of $1 (GET
-- /api/settings?as_of=$1; the salaries table on the Settings page; FR-ST2). One row
-- per level whose salary span covers $1: level + monthly_salary, ordered by level. A
-- level with no salary covering $1 is simply absent. Param: $1 = the as-of date.
SELECT
  salary.level,
  salary.monthly_salary::text AS monthly_salary
FROM salary
WHERE salary.effective_during @> $1::date
ORDER BY salary.level;
"
  |> pog.query
  |> pog.parameter(pog.calendar_date(arg_1))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `salary_revise` query
/// defined in `./src/tempo/server/salary/sql/salary_revise.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type SalaryReviseRow {
  SalaryReviseRow(revised: Int)
}

/// salary_revise.sql — change a level's monthly_salary from $1 onward (Change). FOR
/// PORTION OF re-rates [$1, ∞) of the covering row, setting monthly_salary + audit_id;
/// PG carves off the unchanged [start, $1) remainder keeping its original audit_id.
/// The `@>` guard leaves a scheduled future version untouched. $1 = effective,
/// $2 = new monthly salary (exact decimal text, cast to numeric), $3 = level,
/// $4 = audit_id.
///
/// PG reports `UPDATE 1` even when it produces an extra remainder row, so never
/// infer a split from the affected-row count — read the rows back instead. With no
/// covering version the UPDATE matches nothing and RETURNING yields zero rows; the
/// repository rejects that (NoSuchVersion) rather than journalling a silent no-op.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn salary_revise(
  db: pog.Connection,
  arg_1: Date,
  arg_2: String,
  level: Int,
  audit_id: Int,
) -> Result(pog.Returned(SalaryReviseRow), pog.QueryError) {
  let decoder = {
    use revised <- decode.field(0, decode.int)
    decode.success(SalaryReviseRow(revised:))
  }

  "-- salary_revise.sql — change a level's monthly_salary from $1 onward (Change). FOR
-- PORTION OF re-rates [$1, ∞) of the covering row, setting monthly_salary + audit_id;
-- PG carves off the unchanged [start, $1) remainder keeping its original audit_id.
-- The `@>` guard leaves a scheduled future version untouched. $1 = effective,
-- $2 = new monthly salary (exact decimal text, cast to numeric), $3 = level,
-- $4 = audit_id.
--
-- PG reports `UPDATE 1` even when it produces an extra remainder row, so never
-- infer a split from the affected-row count — read the rows back instead. With no
-- covering version the UPDATE matches nothing and RETURNING yields zero rows; the
-- repository rejects that (NoSuchVersion) rather than journalling a silent no-op.
UPDATE salary
   FOR PORTION OF effective_during FROM $1::date TO NULL
   SET monthly_salary = $2::text::numeric, audit_id = $4
 WHERE level = $3
   AND effective_during @> $1::date
RETURNING 1 AS revised;
"
  |> pog.query
  |> pog.parameter(pog.calendar_date(arg_1))
  |> pog.parameter(pog.text(arg_2))
  |> pog.parameter(pog.int(level))
  |> pog.parameter(pog.int(audit_id))
  |> pog.returning(decoder)
  |> pog.execute(db)
}
