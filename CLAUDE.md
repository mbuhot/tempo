# Layout

- `shared/` — data contracts + JSON codecs + permission policy; compiles to BOTH Erlang and JS.
- `server/` — Wisp API, pog, Squirrel-generated typed SQL (Erlang).
- `client/` — Lustre single-page app (JS).
- `e2e/` — Playwright.
- Organize by domain concept, not by layer. A concept lives in `server/src/tempo/server/<concept>/` as `command.gleam` (writes) + `view.gleam` (reads) + `http.gleam` + `sql/*.sql` + generated `sql.gleam`, with matching `shared/src/shared/<concept>/{command,view}.gleam`.
- Deeper docs: `docs/ARCHITECTURE.md`, `docs/SCHEMA.md`, `docs/DECISIONS.md`. Adding a temporal-fact concept: `docs/ADDING-A-CONCEPT.md`.

# Commands & ports

- DB runs on host port **5435** (the 5434 Docker proxy is wedged). Export `TEMPO_DB_PORT=5435` for `bin/migrate`, `bin/test`, `bin/serve`. `bin/squirrel` hardcodes its URL — run it with `DATABASE_URL=postgres://tempo:tempo@127.0.0.1:5435/tempo`.
- `bin/migrate` applies migrations; `bin/squirrel` regenerates typed SQL by introspecting the live DB — **migrate before squirrel**.
- `bin/test` (DB `tempo_test`, base seed), `bin/e2e` (DB `tempo_e2e`, base + financials seed, **rebuilds the client bundle first**), `bin/serve` (:8000), `bin/build` (client bundle + Sass), `bin/reseed` (destructive full reset).
- Migration files: `server/priv/migrations/YYYYMMDDHHMMSS_name.sql`.

# Temporal facts

- Every attribute is a dated row: `<verb>_during daterange NOT NULL`, `PRIMARY KEY (<keys>, <range> WITHOUT OVERLAPS) DEFERRABLE INITIALLY IMMEDIATE`, `audit_id bigint REFERENCES event_log(id)`, plus a `<table>_audit_id_idx`.
- A change is a new row, never an in-place `UPDATE`. Set-from-a-date is delete-then-insert: `WITH deleted AS (DELETE FROM t FOR PORTION OF <range> FROM $d::date TO NULL WHERE ...) INSERT INTO t (..., <range>, audit_id) VALUES (..., daterange($d::date, NULL, '[)'), $audit)`.
- As-of read: `... <range> @> $d::date`. Decompose a range with `lower()` / `upper()` / `upper_inf()`.

# Write seam

- All writes go through `POST /api/operations` → `command.dispatch` (authorizes via the shared `access/policy`, opens one transaction) → the concept's `route` returns `Recorded(entry: Event(operation, summary, payload), facts: [...])` → `repository.record_facts` appends the `event_log` row and threads its minted `id` as every fact's `audit_id`.
- Adding a command touches these exhaustive sites (the compiler names each): `shared` `Command` union + `encode_command` + `grouped_command_decoder`; `access/policy` `CommandKey` + `requirement` + `key`; server `auth.command_tag`, `command.dispatch_in` route, `fact.Fact`, `repository.write`.
- The audit table is `event_log(id, occurred_at, actor, operation, summary, payload jsonb)`. It records who/when + the encoded command; it does NOT retain prior field values.

# Gotchas

- Clean-build (`gleam clean && gleam build`) after adding a variant to a union (`Command`, `Fact`, `CommandKey`, `OpKind`, `Route`) — incremental builds can mask an inexhaustive `case`.
- Gleam tests use the base seed (no financials); financial-write tests must sign in as Admin. Seed "now" is 2026-06-15.
- Client pages are self-contained MVU with the frozen interface `Model / Msg / init / update / view / refetch`; the global as-of date is owned by the shell and passed into `refetch`, never read as a global.
- Client writes reuse the `ui.gleam` op-form engine (`OpKind` → fields → `build_command` → `api.submit_operation`); permission gating mirrors the server via `shared/access/policy`.
