-- 20260704120000_project_capability.sql — a project's capability demand (#39).
--
-- Same shape as project_requirement (level-based staffing demand) but keyed on
-- capability rather than role level: how much of a given capability the project
-- needs, and over what window. target_level is the minimum rolled-up
-- proficiency (0-4, Phase 1 capability_rollup math) an allocated engineer must
-- meet to count as covering; quantity is how many such engineers the project
-- needs (numeric(4,2) per the design DDL, matching project_requirement).
--
-- WITHOUT OVERLAPS primary key DEFERRABLE INITIALLY IMMEDIATE for the same
-- clear-then-set upsert treatment as project_requirement and the Phase 1
-- temporal tables. The PERIOD FK contains the requirement within the project's
-- run, exactly as project_requirement is contained within project_run.

CREATE TABLE project_capability (
  project_id      int NOT NULL REFERENCES project(id),
  capability_id   int NOT NULL REFERENCES capability(id),
  target_level    int NOT NULL CONSTRAINT project_capability_target_check CHECK (target_level BETWEEN 0 AND 4),
  quantity        numeric(4,2) NOT NULL CONSTRAINT project_capability_quantity_check CHECK (quantity > 0),
  required_during daterange NOT NULL,
  audit_id        bigint REFERENCES event_log(id),
  CONSTRAINT project_capability_no_overlap
    PRIMARY KEY (project_id, capability_id, required_during WITHOUT OVERLAPS)
    DEFERRABLE INITIALLY IMMEDIATE,
  CONSTRAINT project_capability_within_run
    FOREIGN KEY (project_id, PERIOD required_during)
    REFERENCES project_run (project_id, PERIOD active_during)
);
CREATE INDEX project_capability_audit_id_idx ON project_capability (audit_id);
