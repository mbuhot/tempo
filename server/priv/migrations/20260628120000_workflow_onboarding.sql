-- workflow_onboarding — draft storage for the multi-step onboarding wizard (#28).
--
-- A workflow_instance is the draft anchor: its lifecycle status, who owns it (the
-- hiring manager), who it currently awaits (the assignee), and which step is open.
-- Real engineer facts are written only at commit; until then the draft lives here.
--
-- workflow_step_value is transaction-time history, keyed like every other temporal
-- table by `(anchor, recorded_during WITHOUT OVERLAPS)` (ADR-030): the open version
-- (upper_inf) is the current value, superseded versions keep a closed upper bound.
-- A save closes the open span at clock_timestamp() and opens a new one from the same
-- instant (contiguous, non-overlapping); a save whose value is unchanged writes
-- nothing. Retaining the closed spans is what lets a step be read as-of an earlier
-- instant for undo/redo (Phase 2). tstzrange (not daterange) because draft edits
-- happen at sub-day, wall-clock granularity.

CREATE TABLE workflow_instance (
  id           text PRIMARY KEY DEFAULT gen_random_uuid()::text,
  kind         text NOT NULL,
  status       text NOT NULL DEFAULT 'draft'
                 CONSTRAINT workflow_instance_status_check
                 CHECK (status IN ('draft', 'awaiting_finance', 'committed', 'cancelled')),
  owner_id     int  NOT NULL REFERENCES account (id),
  assignee_id  int  REFERENCES account (id),
  current_step text NOT NULL,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE workflow_step_value (
  instance_id     text NOT NULL REFERENCES workflow_instance (id) ON DELETE CASCADE,
  step_id         text NOT NULL,
  field_key       text NOT NULL,
  value           jsonb NOT NULL,
  recorded_during tstzrange NOT NULL,
  -- DEFERRABLE INITIALLY IMMEDIATE so the close-then-open upsert (DELETE FOR PORTION
  -- OF + INSERT in one CTE) is checked once after both apply, not per-row mid-
  -- statement — the same treatment the other upsert-target tables get.
  CONSTRAINT workflow_step_value_no_overlap
    PRIMARY KEY (instance_id, step_id, field_key, recorded_during WITHOUT OVERLAPS)
    DEFERRABLE INITIALLY IMMEDIATE
);

-- Current-value reads probe the open span per instance; a partial index keeps that
-- cheap without indexing the historical (closed) rows.
CREATE INDEX workflow_step_value_current_idx
  ON workflow_step_value (instance_id) WHERE upper_inf(recorded_during);

CREATE INDEX workflow_instance_assignee_idx
  ON workflow_instance (assignee_id) WHERE status = 'awaiting_finance';
