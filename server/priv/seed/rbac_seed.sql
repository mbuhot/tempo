-- rbac_seed.sql — DEV-ONLY: the permission catalog, the role catalog, the role->permission
-- matrix, and the demo accounts' role assignments. Applied by tempo/seed (idempotently,
-- only when the permission catalog is empty), NOT by a migration: a deploy provisions its
-- own roles. Grants are back-dated open-ended ([2024-01-01, ∞)) so they are in force as-of
-- any demo date. All rows share one 'seed_rbac' event_log row for audit provenance.

INSERT INTO event_log (occurred_at, actor, operation, summary, payload)
VALUES ('2024-01-01', 'seed', 'seed_rbac', 'Seed RBAC catalog, matrix, and role assignments', '{}'::jsonb);

INSERT INTO permission (key, description) VALUES
  ('read.projects',       'Read the board, projects, and clients'),
  ('read.engineers',      'Read all engineer data and the activity log'),
  ('read.finances',       'Read invoices, payroll, P&L, and forecast'),
  ('profile.update.own',  'Update your own engineer profile'),
  ('profile.update.any',  'Update any engineer profile'),
  ('timesheet.log.own',   'Log your own timesheet'),
  ('timesheet.log.any',   'Log any engineer timesheet'),
  ('leave.take.own',      'Take your own leave'),
  ('leave.take.any',      'Record any engineer leave'),
  ('engineer.onboard',    'Onboard engineers'),
  ('engineer.promote',    'Promote engineers'),
  ('engineer.terminate',  'Terminate engineers'),
  ('allocation.manage',   'Allocate engineers to projects'),
  ('engagement.manage',   'Sign contracts and start projects'),
  ('project.manage',      'Edit projects and capacity requirements'),
  ('client.manage',       'Edit clients'),
  ('salary.set',          'Set salaries'),
  ('ratecard.manage',     'Revise the rate card'),
  ('invoice.manage',      'Draft, issue, and pay invoices'),
  ('payroll.run',         'Run payroll'),
  ('roles.manage',        'Grant and revoke user roles');

INSERT INTO role (name, description) VALUES
  ('engineer', 'Submit timesheets and manage your own profile'),
  ('manager',  'Manage engineers, projects, and allocations; read finances'),
  ('finance',  'Run payroll, manage invoices, set salaries; view all data'),
  ('owner',    'Full access');

INSERT INTO role_permission (role, permission, granted_during, audit_id)
SELECT m.role, m.permission, daterange('2024-01-01', NULL, '[)'),
       (SELECT id FROM event_log WHERE operation = 'seed_rbac' ORDER BY id DESC LIMIT 1)
FROM (VALUES
  ('engineer', 'read.projects'),
  ('engineer', 'profile.update.own'),
  ('engineer', 'timesheet.log.own'),
  ('engineer', 'leave.take.own'),

  ('manager', 'read.projects'),
  ('manager', 'read.engineers'),
  ('manager', 'read.finances'),
  ('manager', 'profile.update.any'),
  ('manager', 'timesheet.log.any'),
  ('manager', 'leave.take.any'),
  ('manager', 'engineer.onboard'),
  ('manager', 'engineer.promote'),
  ('manager', 'engineer.terminate'),
  ('manager', 'allocation.manage'),
  ('manager', 'engagement.manage'),
  ('manager', 'project.manage'),
  ('manager', 'client.manage'),

  ('finance', 'read.projects'),
  ('finance', 'read.engineers'),
  ('finance', 'read.finances'),
  ('finance', 'salary.set'),
  ('finance', 'ratecard.manage'),
  ('finance', 'invoice.manage'),
  ('finance', 'payroll.run'),

  ('owner', 'read.projects'),
  ('owner', 'read.engineers'),
  ('owner', 'read.finances'),
  ('owner', 'profile.update.own'),
  ('owner', 'profile.update.any'),
  ('owner', 'timesheet.log.own'),
  ('owner', 'timesheet.log.any'),
  ('owner', 'leave.take.own'),
  ('owner', 'leave.take.any'),
  ('owner', 'engineer.onboard'),
  ('owner', 'engineer.promote'),
  ('owner', 'engineer.terminate'),
  ('owner', 'allocation.manage'),
  ('owner', 'engagement.manage'),
  ('owner', 'project.manage'),
  ('owner', 'client.manage'),
  ('owner', 'salary.set'),
  ('owner', 'ratecard.manage'),
  ('owner', 'invoice.manage'),
  ('owner', 'payroll.run'),
  ('owner', 'roles.manage')
) AS m(role, permission);

INSERT INTO user_role (account_id, role, held_during, audit_id)
SELECT a.id, v.role, daterange('2024-01-01', NULL, '[)'),
       (SELECT id FROM event_log WHERE operation = 'seed_rbac' ORDER BY id DESC LIMIT 1)
FROM (VALUES
  ('admin@alembic.com.au',        'owner'),
  ('ops@alembic.com.au',          'manager'),
  ('finance@alembic.com.au',      'finance'),
  ('priya.sharma@alembic.com.au', 'engineer'),
  ('marcus.chen@alembic.com.au',  'engineer'),
  ('aisha.okafor@alembic.com.au', 'engineer')
) AS v(username, role)
JOIN account a ON a.username = v.username;
