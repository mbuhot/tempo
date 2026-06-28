-- step_value_set.sql — record a new transaction-time version of a field, IFF its
-- value changed (#28). A no-op when the incoming value equals the current open
-- version, so tabbing through a field, or an undo/redo that lands on the current
-- value, records nothing.
--
-- `FOR PORTION OF ... FROM now() TO NULL` carves the open slice off, leaving the
-- prior value as the closed history span [lower, now); the INSERT opens the new span
-- from the same now(). now() is the transaction timestamp — every row a transaction
-- writes shares it, so the carve and insert meet exactly (contiguous, no overlap).
-- Each field save is its own request/transaction, so successive saves get distinct
-- instants and history accrues. (clock_timestamp() would give sub-statement instants
-- but is volatile, which FOR PORTION OF bounds forbid.) The portion-carve is the same
-- pattern the other temporal upserts use; a plain range UPDATE can't close-and-open
-- in one statement, as the INSERT would still see the original open span and overlap
-- it. jsonb equality is semantic, so key order in the encoded value never matters.
-- $1 = instance id, $2 = step id, $3 = field key, $4 = value (json text).
WITH changed AS (
  SELECT 1
   WHERE NOT EXISTS (
     SELECT 1 FROM workflow_step_value
      WHERE instance_id = $1 AND step_id = $2 AND field_key = $3
        AND upper_inf(recorded_during) AND value = $4::jsonb
   )
),
carved AS (
  DELETE FROM workflow_step_value
    FOR PORTION OF recorded_during FROM now() TO NULL
   WHERE instance_id = $1 AND step_id = $2 AND field_key = $3
     AND upper_inf(recorded_during)
     AND EXISTS (SELECT 1 FROM changed)
)
INSERT INTO workflow_step_value (instance_id, step_id, field_key, value, recorded_during)
SELECT $1, $2, $3, $4::jsonb, tstzrange(now(), NULL, '[)')
 WHERE EXISTS (SELECT 1 FROM changed);
