-module(tempo_password_ffi).
-export([pbkdf2_sha512/4]).

%% PBKDF2-HMAC-SHA512 via OTP's vetted `crypto` KDF (no native build, unlike an
%% Argon2 NIF). Returns the derived key as a `KeyLength`-byte binary. Wrapped here
%% only to pin the `sha512` digest atom; all policy (iterations, salt, encoding)
%% lives in `tempo/server/account/password`.
pbkdf2_sha512(Password, Salt, Iterations, KeyLength) ->
    crypto:pbkdf2_hmac(sha512, Password, Salt, Iterations, KeyLength).
