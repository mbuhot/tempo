# Adding a temporal-fact concept

The recipe for a new domain concept with a dated fact, a write command, and a read
endpoint. Every step maps to an existing example — `leave` and `engineer_skill` are the
cleanest templates.

## 1. Migration

`server/priv/migrations/<timestamp>_<name>.sql`:

```sql
CREATE TABLE <fact> (
  <anchor>_id  bigint    NOT NULL REFERENCES <anchor> (id),
  <range>      daterange NOT NULL,
  <cols...>,
  audit_id     bigint    REFERENCES event_log (id),
  CONSTRAINT <fact>_no_overlap
    PRIMARY KEY (<anchor>_id, <range> WITHOUT OVERLAPS) DEFERRABLE INITIALLY IMMEDIATE
);
CREATE INDEX <fact>_audit_id_idx ON <fact> (audit_id);
```

Add a `PERIOD` foreign key only when the fact must be contained in a parent span (as
`allocation` is within `employment`); a standalone attribute (like `engineer_contact`)
needs none. Enum-like columns get a named `CHECK` — a `*_check` violation is classified
to `InvalidValue` (422); `*_no_overlap` → `OverlappingFact` (409); `*_within_*` PERIOD FK
→ `ContainmentViolated` (409).

Apply with `bin/migrate`.

## 2. SQL + Squirrel

Queries live in `server/src/tempo/server/<concept>/sql/*.sql`, one per file. The idioms:

- **Set-from-a-date (open-ended supersession):**
  ```sql
  WITH deleted AS (
    DELETE FROM <fact> FOR PORTION OF <range> FROM $2::date TO NULL WHERE <anchor>_id = $1
  )
  INSERT INTO <fact> (<anchor>_id, <cols>, <range>, audit_id)
  VALUES ($1, <vals>, daterange($2::date, NULL, '[)'), $last);
  ```
- **Bounded clear (surgical edit):** `DELETE FROM <fact> FOR PORTION OF <range> FROM $2::date TO $3::date WHERE ...`.
- **As-of read:** join every temporal table with `AND <table>.<range> @> $k::date`; expose bounds as `lower(<range>) AS valid_from`, `upper(<range>) AS valid_to`, `upper_inf(<range>) AS ongoing`.

Regenerate: `cd server && DATABASE_URL=postgres://tempo:tempo@127.0.0.1:5435/tempo gleam run -m squirrel` (after migrating). Read the generated `sql.gleam` for exact fn names, param order, and row-type field names — Squirrel names positional params `arg_N` and decodes `numeric` as `Float`, `date` via `pog.calendar_date_decoder()`, LEFT-JOIN columns as `Option`.

## 3. shared read type + codecs

`shared/src/shared/<concept>/view.gleam`: a record plus a hand-written `encode_*` (via
`gleam/json`) and `*_decoder()` (via `gleam/dynamic/decode`), kept adjacent. Dates go
through `shared/wire` (`encode_date`/`date_decoder`, `encode_option_date`/`option_date_decoder`).
There is no `daterange` in `shared` — carry a period as two `Date` fields. Round-trip test
each variant in `server/test/codec_test.gleam`.

## 4. shared write command

`shared/src/shared/<concept>/command.gleam`: a command type, `encode` (tagged with an
`op` string), and `decoder(op) -> Result(Decoder(..), Nil)` returning `Error(Nil)` for ops
this aggregate doesn't own. Then wire into `shared/src/shared/command.gleam`: a `Command`
variant, an `encode_command` arm, and a `use <- try_group(...)` line in
`grouped_command_decoder`.

## 5. permission + policy

`shared/src/shared/access.gleam`: a `pub const <perm> = "<key>"` and add it to `all()`.
`shared/src/shared/access/policy.gleam`: a `CommandKey` variant, a `requirement` arm
(`Direct(perm)` or `Owned(own, any)`), and a `key(command)` arm. Grant the permission to
roles in `server/priv/seed/rbac_seed.sql`.

## 6. server write path

- `server/src/tempo/server/fact.gleam`: a `Fact` variant carrying the typed anchor ids.
- `server/src/tempo/server/repository.gleam`: a `write` arm mapping the fact to the
  generated clear+set SQL, passing `audit_id` last.
- `server/src/tempo/server/<concept>/command.gleam`: `route(conn, command)` dispatching to
  a per-op fn that returns `Recorded(entry: Event(operation, summary, payload), facts:)`.
  Domain guards (balance, validation) live here and return an `OperationError`; permission
  checks do NOT (they run once in `command.dispatch`).
- `server/src/tempo/server/command.gleam`: a `route` arm.
- `server/src/tempo/server/auth.gleam`: a `command_tag` arm.

Because `Command`, `CommandKey`→`requirement`, `key`, `command_tag`, `route`, and `write`
are exhaustive with no catch-all, omitting any of these is a compile error.

## 7. server read path

`server/src/tempo/server/<concept>/view.gleam` maps Squirrel rows to shared types (small
`*_to_shared` fns; an inner `Result(_, Nil)` signals 404). `http.gleam` parses the request
(`request.date_from_query(req, "as_of")`), calls the view, and encodes
(`response.json_response` / `response.db_error_response`). Register the route in
`web/router.gleam`, gating reads with `guard.require(context, access.<read_perm>)`.

## 8. client

- A page under `client/src/client/page/` with the frozen `Model / Msg / init / update /
  view / refetch` interface; register it in `app.gleam` (`Page` + `Msg` variants,
  route→page, `refetch_page`, msg routing) and add a `Route` in `route.gleam`.
- Fetch with `api.get(url_with_as_of, decoder, to_msg)`; carry `as_of` in every reply msg
  and drop stale replies.
- Writes reuse the `ui.gleam` op engine: an `OpKind`, its `OpField`s and `OpForm` slots,
  `op_command_key` (→ the `policy.CommandKey`), `op_verb`, `build_command`, and the modal
  field list; submit via `api.submit_operation`, refetch on `OperationReturned(Ok(_))`.

## 9. tests

- **codec** (`server/test/codec_test.gleam`): JSON round-trip per shared variant.
- **SQL/read** (`server/test/*_test.gleam`): run generated queries against the base seed
  (now = 2026-06-15), assert exact row records.
- **command** (model on `financials_test.gleam`): build a rollback fixture, drive
  `command.dispatch_in(conn, actor, command)`, assert both the resulting facts and the
  `event_log` row (never assert `occurred_at`). Use `assert x == expected`.
- **e2e** (`e2e/*.spec.js`): `signInAs` → `navigateTo` → op modal → `scrubTo` a date;
  assert user-visible content only. Financial writes need Admin.
- **seed breadth**: when the read fans out over every child per parent (a list, a
  join, a `group by`), the seed gives at least one parent two or more of that child,
  so the multi-item path is exercised.
