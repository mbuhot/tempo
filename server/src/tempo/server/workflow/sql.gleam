//// This module contains the code to run the sql queries defined in
//// `./src/tempo/server/workflow/sql`.
//// > 🐿️ This module was generated automatically using v4.7.0 of
//// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
////

import gleam/dynamic/decode
import gleam/json.{type Json}
import gleam/option.{type Option}
import pog

/// A row you get from running the `instance_by_id` query
/// defined in `./src/tempo/server/workflow/sql/instance_by_id.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type InstanceByIdRow {
  InstanceByIdRow(
    id: String,
    kind: String,
    status: String,
    owner_id: Int,
    assignee_id: Option(Int),
    current_step: String,
  )
}

/// instance_by_id.sql — the draft instance row for an id (#28). Returns 0 or 1 rows.
/// $1 = instance id.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn instance_by_id(
  db: pog.Connection,
  arg_1: String,
) -> Result(pog.Returned(InstanceByIdRow), pog.QueryError) {
  let decoder = {
    use id <- decode.field(0, decode.string)
    use kind <- decode.field(1, decode.string)
    use status <- decode.field(2, decode.string)
    use owner_id <- decode.field(3, decode.int)
    use assignee_id <- decode.field(4, decode.optional(decode.int))
    use current_step <- decode.field(5, decode.string)
    decode.success(InstanceByIdRow(
      id:,
      kind:,
      status:,
      owner_id:,
      assignee_id:,
      current_step:,
    ))
  }

  "-- instance_by_id.sql — the draft instance row for an id (#28). Returns 0 or 1 rows.
-- $1 = instance id.
SELECT id, kind, status, owner_id, assignee_id, current_step
  FROM workflow_instance
 WHERE id = $1;
"
  |> pog.query
  |> pog.parameter(pog.text(arg_1))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// instance_handoff.sql — hand a draft to the Finance queue (#28): move to
/// 'awaiting_finance' and advance the open step to the finance step, so it surfaces
/// for anyone holding the commit permission. No specific assignee — Finance is a pool.
/// $1 = instance id, $2 = finance step id.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn instance_handoff(
  db: pog.Connection,
  arg_1: String,
  arg_2: String,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- instance_handoff.sql — hand a draft to the Finance queue (#28): move to
-- 'awaiting_finance' and advance the open step to the finance step, so it surfaces
-- for anyone holding the commit permission. No specific assignee — Finance is a pool.
-- $1 = instance id, $2 = finance step id.
UPDATE workflow_instance
   SET status = 'awaiting_finance', current_step = $2, updated_at = now()
 WHERE id = $1;
"
  |> pog.query
  |> pog.parameter(pog.text(arg_1))
  |> pog.parameter(pog.text(arg_2))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `instance_list_for` query
/// defined in `./src/tempo/server/workflow/sql/instance_list_for.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type InstanceListForRow {
  InstanceListForRow(
    id: String,
    kind: String,
    status: String,
    current_step: String,
  )
}

/// instance_list_for.sql — the open drafts a user can resume (#28): those they own,
/// plus — when they can commit ($2) — every draft awaiting Finance (the shared queue).
/// Newest first. Committed/cancelled are excluded.
/// $1 = account id, $2 = whether the caller holds the commit permission.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn instance_list_for(
  db: pog.Connection,
  arg_1: Int,
  arg_2: Bool,
) -> Result(pog.Returned(InstanceListForRow), pog.QueryError) {
  let decoder = {
    use id <- decode.field(0, decode.string)
    use kind <- decode.field(1, decode.string)
    use status <- decode.field(2, decode.string)
    use current_step <- decode.field(3, decode.string)
    decode.success(InstanceListForRow(id:, kind:, status:, current_step:))
  }

  "-- instance_list_for.sql — the open drafts a user can resume (#28): those they own,
-- plus — when they can commit ($2) — every draft awaiting Finance (the shared queue).
-- Newest first. Committed/cancelled are excluded.
-- $1 = account id, $2 = whether the caller holds the commit permission.
SELECT id, kind, status, current_step
  FROM workflow_instance
 WHERE status IN ('draft', 'awaiting_finance')
   AND (owner_id = $1 OR ($2 AND status = 'awaiting_finance'))
 ORDER BY updated_at DESC;
"
  |> pog.query
  |> pog.parameter(pog.int(arg_1))
  |> pog.parameter(pog.bool(arg_2))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// instance_set_status.sql — move a draft to a new lifecycle status (#28), e.g.
/// 'committed' or 'cancelled'.
/// $1 = instance id, $2 = status.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn instance_set_status(
  db: pog.Connection,
  arg_1: String,
  arg_2: String,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- instance_set_status.sql — move a draft to a new lifecycle status (#28), e.g.
-- 'committed' or 'cancelled'.
-- $1 = instance id, $2 = status.
UPDATE workflow_instance
   SET status = $2, updated_at = now()
 WHERE id = $1;
"
  |> pog.query
  |> pog.parameter(pog.text(arg_1))
  |> pog.parameter(pog.text(arg_2))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// instance_set_step.sql — advance (or move) the open step of a draft (#28).
/// $1 = instance id, $2 = next step id.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn instance_set_step(
  db: pog.Connection,
  arg_1: String,
  arg_2: String,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- instance_set_step.sql — advance (or move) the open step of a draft (#28).
-- $1 = instance id, $2 = next step id.
UPDATE workflow_instance
   SET current_step = $2, updated_at = now()
 WHERE id = $1;
"
  |> pog.query
  |> pog.parameter(pog.text(arg_1))
  |> pog.parameter(pog.text(arg_2))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `instance_start` query
/// defined in `./src/tempo/server/workflow/sql/instance_start.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type InstanceStartRow {
  InstanceStartRow(id: String)
}

/// instance_start.sql — open a new workflow draft instance (#28).
/// Inserts the anchor in the 'draft' status at its first step, owned by the
/// starting user, and returns the generated id the client routes to.
/// $1 = kind, $2 = owner account id, $3 = first step id.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn instance_start(
  db: pog.Connection,
  arg_1: String,
  arg_2: Int,
  arg_3: String,
) -> Result(pog.Returned(InstanceStartRow), pog.QueryError) {
  let decoder = {
    use id <- decode.field(0, decode.string)
    decode.success(InstanceStartRow(id:))
  }

  "-- instance_start.sql — open a new workflow draft instance (#28).
-- Inserts the anchor in the 'draft' status at its first step, owned by the
-- starting user, and returns the generated id the client routes to.
-- $1 = kind, $2 = owner account id, $3 = first step id.
INSERT INTO workflow_instance (kind, owner_id, current_step)
VALUES ($1, $2, $3)
RETURNING id;
"
  |> pog.query
  |> pog.parameter(pog.text(arg_1))
  |> pog.parameter(pog.int(arg_2))
  |> pog.parameter(pog.text(arg_3))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// step_value_set.sql — record a new transaction-time version of a step document,
/// IFF its value changed (#28). A no-op when the incoming document equals the current
/// open version.
///
/// `FOR PORTION OF ... FROM now() TO NULL` carves the open slice off, leaving the
/// prior document as the closed history span [lower, now); the INSERT opens the new
/// span from the same now(). now() is the transaction timestamp — every row a
/// transaction writes shares it, so the carve and insert meet exactly (contiguous, no
/// overlap). jsonb equality is semantic, so key order in the encoded value never matters.
/// $1 = instance id, $2 = step id, $3 = value (json text).
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn step_value_set(
  db: pog.Connection,
  instance_id: String,
  step_id: String,
  arg_3: Json,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- step_value_set.sql — record a new transaction-time version of a step document,
-- IFF its value changed (#28). A no-op when the incoming document equals the current
-- open version.
--
-- `FOR PORTION OF ... FROM now() TO NULL` carves the open slice off, leaving the
-- prior document as the closed history span [lower, now); the INSERT opens the new
-- span from the same now(). now() is the transaction timestamp — every row a
-- transaction writes shares it, so the carve and insert meet exactly (contiguous, no
-- overlap). jsonb equality is semantic, so key order in the encoded value never matters.
-- $1 = instance id, $2 = step id, $3 = value (json text).
WITH changed AS (
  SELECT 1
   WHERE NOT EXISTS (
     SELECT 1 FROM workflow_step_value
      WHERE instance_id = $1 AND step_id = $2
        AND upper_inf(recorded_during) AND value = $3::jsonb
   )
),
carved AS (
  DELETE FROM workflow_step_value
    FOR PORTION OF recorded_during FROM now() TO NULL
   WHERE instance_id = $1 AND step_id = $2
     AND upper_inf(recorded_during)
     AND EXISTS (SELECT 1 FROM changed)
)
INSERT INTO workflow_step_value (instance_id, step_id, value, recorded_during)
SELECT $1, $2, $3::jsonb, tstzrange(now(), NULL, '[)')
 WHERE EXISTS (SELECT 1 FROM changed);
"
  |> pog.query
  |> pog.parameter(pog.text(instance_id))
  |> pog.parameter(pog.text(step_id))
  |> pog.parameter(pog.text(json.to_string(arg_3)))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `step_values_current` query
/// defined in `./src/tempo/server/workflow/sql/step_values_current.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type StepValuesCurrentRow {
  StepValuesCurrentRow(step_id: String, value: String)
}

/// step_values_current.sql — the current step document for every step in a draft:
/// the open (unbounded-upper) version per step. The WITHOUT OVERLAPS PK guarantees
/// exactly one open span per (instance_id, step_id).
/// $1 = instance id.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn step_values_current(
  db: pog.Connection,
  instance_id: String,
) -> Result(pog.Returned(StepValuesCurrentRow), pog.QueryError) {
  let decoder = {
    use step_id <- decode.field(0, decode.string)
    use value <- decode.field(1, decode.string)
    decode.success(StepValuesCurrentRow(step_id:, value:))
  }

  "-- step_values_current.sql — the current step document for every step in a draft:
-- the open (unbounded-upper) version per step. The WITHOUT OVERLAPS PK guarantees
-- exactly one open span per (instance_id, step_id).
-- $1 = instance id.
SELECT step_id, value::text
  FROM workflow_step_value
 WHERE instance_id = $1 AND upper_inf(recorded_during)
 ORDER BY step_id;
"
  |> pog.query
  |> pog.parameter(pog.text(instance_id))
  |> pog.returning(decoder)
  |> pog.execute(db)
}
