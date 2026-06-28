-- step_value_set.sql — record a new transaction-time version of a step document,
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
