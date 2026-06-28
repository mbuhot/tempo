-- workflow_onboarding — draft storage for the multi-step onboarding wizard (#28).
--
-- A workflow_instance is the draft anchor: its lifecycle status, who owns it (the
-- hiring manager), who it currently awaits (the assignee), and which step is open.
-- Real engineer facts are written only at commit; until then the draft lives here.
--
-- workflow_step_value is append-only transaction-time history: every save inserts a
-- new row stamped at clock_timestamp() (which advances within a transaction, so
-- successive saves order correctly even inside one request). The current value of a
-- field is the latest row for that (instance_id, field_key). Retaining history is
-- what later lets a step be read as-of an earlier instant for undo/redo.

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
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  instance_id text NOT NULL REFERENCES workflow_instance (id) ON DELETE CASCADE,
  step_id     text NOT NULL,
  field_key   text NOT NULL,
  value       jsonb NOT NULL,
  recorded_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE INDEX workflow_step_value_current_idx
  ON workflow_step_value (instance_id, field_key, recorded_at DESC, id DESC);

CREATE INDEX workflow_instance_assignee_idx
  ON workflow_instance (assignee_id) WHERE status = 'awaiting_finance';
