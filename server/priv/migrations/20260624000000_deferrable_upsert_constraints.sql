-- Make the WITHOUT OVERLAPS primary keys on all upsert-target tables DEFERRABLE
-- INITIALLY IMMEDIATE so that DELETE FOR PORTION OF + INSERT can run in a single
-- CTE statement. The whole CTE is one statement, so the exclusion constraint is
-- checked once after both the DELETE and INSERT have been applied — no conflict.
-- INITIALLY IMMEDIATE (not DEFERRED) preserves the per-statement check for all
-- other inserts, so constraint tests that expect immediate rejection still pass.

ALTER TABLE client_profile
  DROP CONSTRAINT client_profile_no_overlap,
  ADD  CONSTRAINT client_profile_no_overlap
    PRIMARY KEY (client_id, recorded_during WITHOUT OVERLAPS) DEFERRABLE INITIALLY IMMEDIATE;

ALTER TABLE engineer_banking
  DROP CONSTRAINT engineer_banking_no_overlap,
  ADD  CONSTRAINT engineer_banking_no_overlap
    PRIMARY KEY (engineer_id, recorded_during WITHOUT OVERLAPS) DEFERRABLE INITIALLY IMMEDIATE;

ALTER TABLE engineer_contact
  DROP CONSTRAINT engineer_contact_no_overlap,
  ADD  CONSTRAINT engineer_contact_no_overlap
    PRIMARY KEY (engineer_id, recorded_during WITHOUT OVERLAPS) DEFERRABLE INITIALLY IMMEDIATE;

ALTER TABLE engineer_emergency
  DROP CONSTRAINT engineer_emergency_no_overlap,
  ADD  CONSTRAINT engineer_emergency_no_overlap
    PRIMARY KEY (engineer_id, recorded_during WITHOUT OVERLAPS) DEFERRABLE INITIALLY IMMEDIATE;

ALTER TABLE engineer_role
  DROP CONSTRAINT engineer_role_no_overlap,
  ADD  CONSTRAINT engineer_role_no_overlap
    PRIMARY KEY (engineer_id, held_during WITHOUT OVERLAPS) DEFERRABLE INITIALLY IMMEDIATE;

ALTER TABLE project_plan
  DROP CONSTRAINT project_plan_no_overlap,
  ADD  CONSTRAINT project_plan_no_overlap
    PRIMARY KEY (project_id, planned_during WITHOUT OVERLAPS) DEFERRABLE INITIALLY IMMEDIATE;

ALTER TABLE project_profile
  DROP CONSTRAINT project_profile_no_overlap,
  ADD  CONSTRAINT project_profile_no_overlap
    PRIMARY KEY (project_id, recorded_during WITHOUT OVERLAPS) DEFERRABLE INITIALLY IMMEDIATE;
