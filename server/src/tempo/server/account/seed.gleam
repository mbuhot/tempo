//// DEV-ONLY login accounts: the demo principals provisioned as password accounts, all
//// sharing one documented dev password. The single source of truth for the dev
//// credentials — `tempo/seed` provisions them (PBKDF2-hashed) and the gleam test login
//// helper reads the same list, so they never drift. The e2e suite hardcodes the same
//// `dev_password` (e2e/helpers.js). Roles are NOT here: they live in the temporal
//// `user_role` map, seeded by `rbac_seed.sql` keyed by these usernames. `engineer_id`
//// is linked from a username's matching engineer email by `account_upsert`.

import gleam/list
import pog
import tempo/server/account/password
import tempo/server/account/sql

/// The shared password for every seeded dev account. NOT a secret: it exists only in a
/// dev database the seed can wipe, and is documented in the design doc + e2e helpers.
pub const dev_password = "tempo-dev-password"

/// One seeded login account: the username (an email) and the journal display name.
pub type DevAccount {
  DevAccount(username: String, display_name: String)
}

/// The demo cast as login accounts — the three engineers plus the non-engineer roles
/// (Admin/Ops/Finance), keyed by email. The engineer usernames match their seeded
/// engineer_contact email, so `account_upsert` links each to its engineer record.
pub fn dev_accounts() -> List(DevAccount) {
  [
    DevAccount("priya.sharma@alembic.com.au", "Priya Sharma"),
    DevAccount("marcus.chen@alembic.com.au", "Marcus Chen"),
    DevAccount("aisha.okafor@alembic.com.au", "Aisha Okafor"),
    DevAccount("admin@alembic.com.au", "Admin"),
    DevAccount("ops@alembic.com.au", "Ops"),
    DevAccount("finance@alembic.com.au", "Finance"),
  ]
}

/// Provision every dev account with an idempotent upsert, hashing `dev_password` fresh
/// per account. Safe to re-run: an existing username is left untouched, so this
/// backfills accounts on an already-seeded DB without clobbering passwords.
pub fn seed(db: pog.Connection) -> Result(Nil, pog.QueryError) {
  use account <- list.try_each(dev_accounts())
  sql.account_upsert(
    db,
    account.username,
    account.display_name,
    password.hash(dev_password),
  )
}
