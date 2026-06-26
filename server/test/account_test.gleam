import gleam/option.{None, Some}
import tempo/server/account/seed
import tempo/server/account/view as account
import test_pool

pub fn authenticate_accepts_correct_credentials_and_links_engineer_test() {
  let db = test_pool.db()

  let assert Ok(admin) =
    account.authenticate(db, "admin@alembic.com.au", seed.dev_password)
  assert admin.display_name == "Admin"
  assert admin.engineer_id == None

  let assert Ok(priya) =
    account.authenticate(db, "priya.sharma@alembic.com.au", seed.dev_password)
  assert priya.display_name == "Priya Sharma"
  assert priya.engineer_id == Some(1)
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
