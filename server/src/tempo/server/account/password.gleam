//// Password hashing for login credentials. PBKDF2-HMAC-SHA512 over OTP's vetted
//// `crypto` KDF: an Argon2 NIF won't link on this toolchain, and PBKDF2 needs no
//// native build while staying OWASP-acceptable at a high iteration count. A stored
//// hash is a self-describing string `pbkdf2-sha512$<iterations>$<salt-b64>$<key-b64>`,
//// so the work factor lives in the data and a future cost bump re-hashes without a
//// schema change. `verify` recomputes the derived key under the STORED salt and
//// iterations and compares in constant time (no early-exit timing oracle).

import gleam/bit_array
import gleam/crypto
import gleam/int
import gleam/result
import gleam/string

/// OWASP-recommended floor for PBKDF2-HMAC-SHA512 (2023): re-derive at this cost on
/// every hash and verify. Stored in the encoded hash so an older row still verifies.
const iterations = 210_000

const salt_length = 16

const key_length = 64

const scheme = "pbkdf2-sha512"

@external(erlang, "tempo_password_ffi", "pbkdf2_sha512")
fn pbkdf2_sha512(
  password: BitArray,
  salt: BitArray,
  iterations: Int,
  key_length: Int,
) -> BitArray

/// Hash a plaintext password into a self-describing PHC-style string with a fresh
/// random salt — two hashes of the same password differ.
pub fn hash(password: String) -> String {
  let salt = crypto.strong_random_bytes(salt_length)
  let derived = pbkdf2_sha512(<<password:utf8>>, salt, iterations, key_length)
  encode(iterations, salt, derived)
}

/// True when `password` reproduces the derived key stored in `encoded` (recomputed
/// under its salt + iterations). A malformed `encoded` is `False`, never a crash.
pub fn verify(encoded: String, password: String) -> Bool {
  case decode(encoded) {
    Ok(#(stored_iterations, salt, expected)) ->
      crypto.secure_compare(
        pbkdf2_sha512(<<password:utf8>>, salt, stored_iterations, key_length),
        expected,
      )
    Error(Nil) -> False
  }
}

fn encode(iterations: Int, salt: BitArray, derived: BitArray) -> String {
  string.join(
    [scheme, int.to_string(iterations), base64(salt), base64(derived)],
    "$",
  )
}

fn base64(bytes: BitArray) -> String {
  bit_array.base64_encode(bytes, True)
}

fn decode(encoded: String) -> Result(#(Int, BitArray, BitArray), Nil) {
  case string.split(encoded, "$") {
    [found_scheme, iterations, salt, derived] if found_scheme == scheme -> {
      use iterations <- result.try(int.parse(iterations))
      use salt <- result.try(bit_array.base64_decode(salt))
      use derived <- result.map(bit_array.base64_decode(derived))
      #(iterations, salt, derived)
    }
    _ -> Error(Nil)
  }
}
