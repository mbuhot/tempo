//// Tests for access resolution against the seeded temporal RBAC: an account's effective
//// permissions (the union of role_permission over its current roles) and the Access
//// page snapshot (catalog + matrix + users).

import gleam/list
import gleam/option.{None, Some}
import gleam/set
import shared/access
import tempo/server/access/view as access_view
import tempo/server/account/seed
import tempo/server/account/view as account
import test_pool

fn account_id(username: String) -> Int {
  let assert Ok(found) =
    account.authenticate(test_pool.db(), username, seed.dev_password)
  found.id
}

pub fn resolve_gives_owner_every_permission_test() {
  let assert Ok(principal) =
    access_view.resolve(test_pool.ctx(), account_id("admin@alembic.com.au"))
  assert set.contains(principal.permissions, access.roles_manage)
  assert set.contains(principal.permissions, access.payroll_run)
  assert set.contains(principal.permissions, access.engineer_promote)
  assert principal.engineer_id == None
}

pub fn resolve_gives_engineer_only_its_own_permissions_test() {
  let assert Ok(principal) =
    access_view.resolve(
      test_pool.ctx(),
      account_id("priya.sharma@alembic.com.au"),
    )
  assert set.contains(principal.permissions, access.read_projects)
  assert set.contains(principal.permissions, access.timesheet_log_own)
  assert !set.contains(principal.permissions, access.read_finances)
  assert !set.contains(principal.permissions, access.engineer_promote)
  assert principal.engineer_id == Some(1)
}

pub fn resolve_gives_finance_money_but_not_people_permissions_test() {
  let assert Ok(principal) =
    access_view.resolve(test_pool.ctx(), account_id("finance@alembic.com.au"))
  assert set.contains(principal.permissions, access.payroll_run)
  assert set.contains(principal.permissions, access.invoice_manage)
  assert set.contains(principal.permissions, access.read_engineers)
  assert !set.contains(principal.permissions, access.allocation_manage)
  assert !set.contains(principal.permissions, access.engineer_promote)
}

pub fn snapshot_lists_roles_permissions_matrix_and_users_test() {
  let assert Ok(snapshot) = access_view.snapshot(test_pool.ctx())
  assert list.length(snapshot.roles) == 4
  assert list.length(snapshot.permissions) == 22
  assert list.any(snapshot.matrix, fn(grant) {
    grant.role == access.role_owner && grant.permission == access.roles_manage
  })
  let assert Ok(admin) =
    list.find(snapshot.users, fn(user) {
      user.username == "admin@alembic.com.au"
    })
  assert list.contains(admin.roles, access.role_owner)
}
