import tempo/server/account/seed
import tempo/server/account/view as account
import tempo/server/auth.{Admin, Engineer, Principal}
import test_pool

pub fn authenticate_accepts_correct_credentials_and_yields_the_principal_test() {
  let db = test_pool.db()
  assert account.authenticate(db, "admin@alembic.com.au", seed.dev_password)
    == Ok(Principal(actor: "Admin", role: Admin))
  assert account.authenticate(
      db,
      "priya.sharma@alembic.com.au",
      seed.dev_password,
    )
    == Ok(Principal(actor: "Priya Sharma", role: Engineer))
}

pub fn authenticate_rejects_a_wrong_password_test() {
  let db = test_pool.db()
  assert account.authenticate(db, "admin@alembic.com.au", "not the password")
    == Error(account.BadPassword)
}

pub fn authenticate_rejects_an_unknown_username_test() {
  let db = test_pool.db()
  assert account.authenticate(db, "mallory@alembic.com.au", seed.dev_password)
    == Error(account.UnknownUser)
}
