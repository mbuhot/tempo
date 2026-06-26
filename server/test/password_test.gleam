import tempo/server/account/password

pub fn verify_accepts_the_correct_password_and_rejects_a_wrong_one_test() {
  let stored = password.hash("tempo-dev-password")
  assert password.verify(stored, "tempo-dev-password")
  assert !password.verify(stored, "tempo-dev-passwerd")
}

pub fn each_hash_uses_a_fresh_salt_test() {
  assert password.hash("same input") != password.hash("same input")
}

pub fn verify_rejects_a_malformed_hash_rather_than_crashing_test() {
  assert !password.verify("not-a-real-hash", "anything")
  assert !password.verify("", "anything")
}
