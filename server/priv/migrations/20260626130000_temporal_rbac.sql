-- 20260626130000_temporal_rbac.sql — temporal role-based access control.
--
-- Permissions are a static catalog ("permissions just exist"); a role NAMES a set of
-- permissions; both the role->permission map and the user->role map are TEMPORAL facts
-- (daterange + WITHOUT OVERLAPS + audit_id provenance, the ADR-030 idiom) so a grant is
-- effective-dated and auditable as-of any date. A user's effective permissions =
-- the union of role_permission over every role they hold, as-of CURRENT_DATE.
--
-- Parents here (role, permission, account) are NOT temporal facts, so plain FKs — no
-- PERIOD foreign key like engineer_role's containment chain.

CREATE TABLE permission (
  key         text PRIMARY KEY,
  description text NOT NULL
);

CREATE TABLE role (
  name        text PRIMARY KEY,
  description text NOT NULL
);

-- Which permissions a role grants, over time.
CREATE TABLE role_permission (
  role           text NOT NULL REFERENCES role (name),
  permission     text NOT NULL REFERENCES permission (key),
  granted_during daterange NOT NULL,
  audit_id       bigint REFERENCES event_log (id),
  CONSTRAINT role_permission_no_overlap
    PRIMARY KEY (role, permission, granted_during WITHOUT OVERLAPS)
);

-- Which roles a user (account) holds, over time. A user may hold several roles at
-- once (distinct role rows); WITHOUT OVERLAPS only forbids the SAME (account, role)
-- overlapping itself.
CREATE TABLE user_role (
  account_id  int NOT NULL REFERENCES account (id),
  role        text NOT NULL REFERENCES role (name),
  held_during daterange NOT NULL,
  audit_id    bigint REFERENCES event_log (id),
  CONSTRAINT user_role_no_overlap
    PRIMARY KEY (account_id, role, held_during WITHOUT OVERLAPS)
);

CREATE INDEX role_permission_audit_id_idx ON role_permission (audit_id);
CREATE INDEX user_role_audit_id_idx ON user_role (audit_id);

-- Link an account to its engineer (for ownership checks); role is now temporal in
-- user_role, so the static account.role column is dropped.
ALTER TABLE account ADD COLUMN engineer_id int REFERENCES engineer (id);
ALTER TABLE account DROP COLUMN role;
