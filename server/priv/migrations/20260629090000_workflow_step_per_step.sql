-- workflow_step_per_step — change the draft value store unit from per-field to
-- per-step: one JSON document per step, keyed (instance_id, step_id).
-- Draft data is wipeable; the old table is dropped and recreated without field_key.

DROP TABLE IF EXISTS workflow_step_value;

CREATE TABLE workflow_step_value (
  instance_id     text NOT NULL REFERENCES workflow_instance (id) ON DELETE CASCADE,
  step_id         text NOT NULL,
  value           jsonb NOT NULL,
  recorded_during tstzrange NOT NULL,
  CONSTRAINT workflow_step_value_no_overlap
    PRIMARY KEY (instance_id, step_id, recorded_during WITHOUT OVERLAPS)
    DEFERRABLE INITIALLY IMMEDIATE
);

CREATE INDEX workflow_step_value_current_idx
  ON workflow_step_value (instance_id) WHERE upper_inf(recorded_during);
