//// DEV-ONLY login accounts: the five demo principals provisioned as real password
//// accounts, all sharing one documented dev password. This is the single source of
//// truth for the dev credentials — `tempo/seed` provisions them (PBKDF2-hashed) and
//// the gleam test login helper reads the same list, so the two never drift. The e2e
//// suite hardcodes the same `dev_password` string (e2e/helpers.js).

import gleam/list
import pog
import tempo/server/account/password
import tempo/server/account/sql

/// The shared password for every seeded dev account. NOT a secret: it exists only in a
/// dev database the seed can wipe, and is documented in the design doc + e2e helpers.
pub const dev_password = "tempo-dev-password"

/// One seeded login account: the username (an email), the journal `display_name`
/// (unchanged from the demo gate), and the role string (matches `auth.Role`'s wire
/// form: "admin" | "ops" | "engineer").
pub type DevAccount {
  DevAccount(username: String, display_name: String, role: String)
}

/// The demo cast as login accounts — the same identities the old demo gate offered,
/// now with real credentials keyed by each person's seeded email.
pub fn dev_accounts() -> List(DevAccount) {
  [
    DevAccount("priya.sharma@alembic.com.au", "Priya Sharma", "engineer"),
    DevAccount("marcus.chen@alembic.com.au", "Marcus Chen", "engineer"),
    DevAccount("aisha.okafor@alembic.com.au", "Aisha Okafor", "engineer"),
    DevAccount("admin@alembic.com.au", "Admin", "admin"),
    DevAccount("ops@alembic.com.au", "Ops", "ops"),
  ]
}

/// Provision every dev account with an idempotent upsert, hashing `dev_password` fresh
/// (own salt) per account. Safe to re-run: an existing username is left untouched, so
/// this backfills accounts even on an already-seeded DB without clobbering passwords.
pub fn seed(db: pog.Connection) -> Result(Nil, pog.QueryError) {
  use account <- list.try_each(dev_accounts())
  sql.account_upsert(
    db,
    account.username,
    account.display_name,
    account.role,
    password.hash(dev_password),
  )
}
