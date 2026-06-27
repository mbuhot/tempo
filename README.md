# tempo

A consultancy-staffing system — engineers, clients, contracts, projects, allocations,
timesheets, leave, invoices, payroll, P&L, and a forward forecast — built on
**PostgreSQL 19 application-time temporal tables**. The organising idea is one axis:
you view the whole company *as of* any chosen date, past or future, and the schema never
overwrites state — it records dated **facts** and supersedes them.

This README is a tour of the architecture and the reasoning behind it. `docs/` holds the
deeper references: the requirements, the technical design, the decision log, and a schema
map regenerated from the live database.

---

## Stack and the type flow

| Concern | Tech |
|---|---|
| Database | PostgreSQL 19 — application-time temporal tables (`WITHOUT OVERLAPS`, `PERIOD` foreign keys, `FOR PORTION OF`) |
| Typed SQL | Squirrel — generates typed Gleam from `.sql` files by introspecting the live database |
| DB driver | pog |
| Web server / JSON API | Wisp + mist (Erlang target) |
| Frontend | Lustre SPA + modem (routing) + rsvp (HTTP) (JavaScript target) |
| API contract | a `shared` Gleam package compiled to **both** targets |

```
PG temporal schema
   │  Squirrel introspects the live DB and generates …
   ▼
typed query rows (sql.gleam)         ── server only (Erlang)
   │  mapped to API types
   ▼
shared types + JSON codecs           ── BOTH targets
   │  JSON over HTTP
   ▼
Lustre model / view                  ── client only (JavaScript)
```

A schema change that breaks a query is caught at Squirrel **codegen / compile time**; a
change to a `shared` type breaks **both** the server and client builds until they are
reconciled. The query boundary is explicit and the temporal SQL is the model — the type
system carries it end to end, from the database to the browser.

## Repository layout — four packages

Three sibling Gleam packages wired by path dependencies, plus a Node harness:

```
shared/   target-agnostic — the API contract (types + JSON codecs), compiled for Erlang AND JS
server/   the Wisp server (Erlang target); path-depends on ../shared
client/   the Lustre SPA (JavaScript target); path-depends on ../shared
e2e/      Playwright (Node) — drives the real app, asserts only what the user sees
bin/      thin task wrappers run from the repo root (each cd's into the right package)
docs/     requirements, architecture, the decision log, the schema map
```

The split is a compiler requirement. Gleam compiles a *whole package* per target with no
per-module target exclusion, so a single package holding both the Lustre client and the
`pog`/`wisp`/`mist` server fails to build for JavaScript: the JS compile type-checks the
Erlang-only server modules (including Squirrel's generated `@external(erlang, …)` SQL
bindings) and errors. Path dependencies on `shared` keep the client's dependency graph free
of server code while preserving one source of truth for the wire contract, and a fresh clone
or CI build resolves them unchanged.

Each domain concept is a directory under `server/src/tempo/server/<concept>/` and
`shared/src/shared/<concept>/`, split CQRS-style: `command.gleam` (the write model),
`view.gleam` (the read model), `http.gleam` (the handler), and `sql/` (the `.sql` sources
Squirrel compiles into `sql.gleam`). The same concept name appears on both sides of the
wire, so the contract is read in one place.

## The temporal data model

Every entity is an **id-only anchor** (`engineer`, `client`, `contract`, `project`,
`invoice`, `payroll_run` are bare `(id)` rows). All attributes live in **fact tables**
keyed to the anchor, in one of three flavours, and the read mode is chosen per query:

- **Valid-time facts, read as-of a date.** The period is named for the predicate it
  asserts — `employed_during`, `held_during`, `allocated_during`, `on_leave_during`,
  `term`, `active_during`, `effective_during`, `status_during`, `work_day`. The slider
  reads the version in force on the chosen date. Recorded as a dated fact, "what was her
  charge rate on that day in 2024?" is a plain as-of query, the history is preserved, and a
  promotion seeded ahead activates on its own date.
- **Latest-read facts, period `recorded_during`.** Descriptive detail (contact, banking,
  emergency, profiles) where a new edit is a new `[effective, NULL)` row and the
  most-recently-effective row is current truth; older rows are history. Current value is
  exposed via `*_current` views. These key the anchor with a *plain* (non-PERIOD) FK,
  because a name and bank account are properties of the person that outlive any single
  employment span, so an ex-employee still has them on file.
- **Immutable 1:1 subjects** set once (`invoice_subject`, `payroll_period`); reads
  inner-join them directly.

Mechanisms that do the work:

- **`daterange ... WITHOUT OVERLAPS` primary keys** make "two versions of the same fact
  can't overlap" a database constraint — one charge rate per level at a time, enforced by
  the engine.
- **`PERIOD` foreign keys** chain containment so it reads as a sentence —
  `contract_terms → project_run → allocation → timesheet`, and
  `employment → {engineer_role, leave, allocation}`. Logging time to a project an engineer
  is allocated to that day is the only write the database accepts.
- **`FOR PORTION OF` writes** express a change as cap-the-current-version-and-assert-a-new-one
  natively: `UPDATE … FOR PORTION OF p FROM $effective TO NULL SET … WHERE p @> $effective`.
  The engine produces the temporal leftovers and deletes a fully-covered row itself, so the
  change stays one statement. Open-ended versioned attributes are one writable-CTE upsert —
  the `FOR PORTION OF` change plus an `INSERT … WHERE NOT EXISTS` that opens the founding
  span only when nothing was there yet, so the first write and a later edit are the same
  statement.
- **`EXCLUDE` constraints** carry no-overlap where there is no anchor PK to put it on
  (`payroll_period`).
- **Provenance via `audit_id`.** Every fact row carries a nullable `audit_id` FK into
  `event_log`, set at write time, so a row joins back to the command that recorded it and
  "everything command X touched" is one query. The as-of reads ignore it — it serves
  provenance alone.

The model is **application-time only**: each fact has one timeline, so back-dating a fact
supersedes the previously-held belief, and a correction is the same write as a retroactive
change. The wall-clock axis is recorded once, in the append-only `event_log` (who did what,
when), written in the same transaction as the facts it describes.

PostgreSQL **19** is required for `WITHOUT OVERLAPS`, `PERIOD` FKs, and `FOR PORTION OF`, so
it runs in Docker. With no production database to
migrate forward, the schema is one readable `001_schema.sql` that builds the final state in
a single pass; later feature work (performance indexes, proration views, deferrable
constraints, account credentials, temporal RBAC) lands as timestamped migrations on top of
it. The deterministic demo cast is applied separately from `priv/seed/base_seed.sql` (plus
`rbac_seed.sql`), so a freshly-migrated database is empty until seeded.

## The write path — one command vocabulary, one transaction

A typed **`Command`** union lives in `shared` (the client encodes it, the server decodes the
same value) and every write — onboarding, promotion, allocation, leave, rate revision,
invoicing, payroll — goes through a single `POST /api/operations`. One command vocabulary
runs end to end, matching the shared-contract thesis.

`command.dispatch` (`server/src/tempo/server/command.gleam`) is the seam:

1. **Authorize** the principal against the command (see below) before any transaction opens,
   so a denied command never touches the database.
2. Open **one** `pog.transaction`, **route** the command to its aggregate's `command.gleam`,
   which returns a `fact.Recorded(entry, facts)` — the audit entry plus the facts the command
   records (anchors first, then the facts contained by them).
3. Hand them to `repository.record_facts`, the one place a fact's write *semantics* live: it
   appends the `entry` to `event_log`, then writes each fact, passing the appended entry's id
   as the `audit_id` every fact carries. Journal entry and facts commit together or roll back
   together.

The `route` case is exhaustive over `Command`, so a new command with no arm fails to
compile. `dispatch_in` is the transaction-free core, so a test can drive it inside its own
rolled-back transaction.

`fact.Fact` is the typed information schema: its variants are *states that hold over a
period* (`EngineerEmployed`, `AtLevel`, `AllocatedToProject`, the detail facts, `RateCard`,
`Salary`, the invoice/payroll facts, the retraction facts). Anchor ids are strongly typed
(`EngineerId`, `ProjectId`, …) and minted by `create_*` functions, so an engineer id cannot
land in a project-id position.

Temporal integrity is enforced by the database. Every `PERIOD` FK and exclusion constraint
has a stable name, and a rejection is classified by SQLSTATE + constraint name into a typed
`OperationError` (`ContainmentViolated` / `OverlappingFact` / `InvalidValue` /
`InsufficientLeaveBalance` / …) mapped to an HTTP status (409 / 422 / 500; 503 when the
connection pool is saturated). The domain issues the write, lets the database judge it, and
translates a rejection into a domain-meaningful, testable error.

## The read path

Each concept's `view.gleam` reads through its Squirrel-generated `sql.gleam`. Several reads
are derived on the fly from the facts, so they stay in step:

- **The board** is three all-inner-join as-of queries (on-project / unassigned / on-leave),
  merged and sorted by name. Inner joins let Squirrel type each column's nullability
  soundly, so an engineer who is employed but unallocated on a given date surfaces through
  the `Unassigned` variant.
- **Leave balance** is a pure as-of calculation (accrued − taken, leap-aware).
- **P&L revenue** is capacity-based accrual — the billable value of work performed
  (allocation × rate, split on the role and rate-card versions), recognized as work is done
  and independent of the invoice lifecycle, so an in-progress month shows its earned value.
  The **forecast** is the demand-side mirror: forward revenue from committed capacity
  requirements, falling back to allocations.

A single board tick fans ~5 independent as-of queries out across the connection pool
concurrently (`server/src/tempo/server/async.gleam`); the pool is sized so a few overlapping
scrubs do not queue. List endpoints are keyset-paginated.

## Money

Money is exact decimal, carried by `shared/money` over a bigdecimal, because currency must
be represented to the cent and rounding error is unacceptable in invoices and payroll. The
database seam reads money as `numeric::text` and writes it as `$N::text::numeric`, so no
precision is lost crossing the driver. Ratios (fractions, margins, utilization) stay `Float`.

## Authentication and authorization

The application has real password authentication and a temporal role/permission system.

- **Passwords** are hashed with PBKDF2-HMAC-SHA512 via the OTP `crypto` FFI, which needs no
  native dependency on the target platform.
- **Sessions** are a signed cookie carrying **only the account id**. Roles and permissions
  are temporal and resolved from the database as-of *each* request, so a revoked role takes
  effect immediately. "Remember me" is a separate opt-in (a persistent cookie vs a session
  cookie); a signed cookie cannot be forged.
- **The principal is resolved once per request** by a middleware at the top of the router,
  into a request-scoped `Context.principal`; the route guards are then pure reads of it
  (401/403, no cookie or DB work). An unauthenticated request has no cookie, so it pays no
  query.
- **Roles are temporal.** Permissions are atomic keys; a role is a composed set of them; both
  the `role_permission` and `user_role` maps are themselves temporal facts, so a principal's
  effective permissions are the union resolved as-of today. An Owner-only Access page
  visualises the role→permission matrix and grants/revokes user roles through the same
  command bus.
- **One authorization policy, shared.** `shared/access/policy` maps each command to its
  requirement (`Direct(permission)` or, for ownership-sensitive commands, `Owned(own, any)`)
  and holds the `satisfies` predicate. The **server enforcement gate and the client's UI
  gating consult the same module**, so the two stay in step; reads are gated by their single
  required permission directly.
- **The client gate is a capability.** A page's "start this operation" message carries an
  opaque `ui.Permit` instead of a command kind, and the only way to mint one is the shared
  permission check. Because `Permit` is opaque, an ungated or wrong-permission launcher
  fails to compile. The server remains the boundary regardless.
- On boot the client restores its session from the cookie via `GET /api/me`, which returns
  the same effective permissions the server will enforce.

## The client — a Lustre SPA

The client is Model-View-Update: an `app.gleam` shell (the top-level model, the global as-of
date, the login gate, the sidebar, and the `modem` router) plus one module per page under
`client/page/`. Each page implements a frozen interface — `init` / `update` / `view` /
`refetch` — and communicates with the shell only through an `OutMsg` (`Navigate` or
`OperationCommitted`); pages never import each other's internals.

- **One global as-of date** is the application's spine: a time rail owns it, mirrored in the
  URL (`?date=YYYY-MM-DD`), and every page resolves its valid-time views against it. The
  **Activity** journal runs on system time (when changes were recorded) — a separate axis
  from the as-of rail, so it keeps its own timeline. Scrubbing the rail gives an instant
  readout and a debounced refetch.
- Writes are **contextual operations**: Assign / Roll off on a board card, Promote / Take
  leave on a person, Issue / Mark paid on an invoice — each opens a small form pre-scoped to
  its subject, composes the same `Command`, and posts it. A refused operation shows its typed
  domain error inline.
- The form machinery (`OpKind` / `OpForm` / `build_command`) is one shared engine, so every
  page composes commands the same way.
- CSS is token-only and modular: every rule references a `var(--token)` from one `theme.css`,
  compiled by Sass (shared declaration clusters are `@mixin`s) and guarded by a lint
  (`bin/lint-css`) that fails the build on a reference to an undefined token.

## Testing

Each guarantee is checked at the cheapest level that can prove it:

- **Gleam tests** (`cd server && gleam test`) — DB-level temporal-constraint tests, as-of
  query tests, shared-codec round-trips, and HTTP-layer tests that drive the real Wisp
  handlers and assert the decoded JSON. Three connection pools back them for three reasons:
  a **shared** pool for the rolled-back majority, a **serial** pool for reads that must commit
  and fan out concurrently (a spawned fan-out cannot share one in-transaction connection), and
  a dedicated **concurrency** pool for the two-connection read-modify-write race tests (the
  race only exists across committed transactions).
- **Playwright** (`bin/e2e`) — one spec per UI surface, driving the real app in a browser and
  asserting only what the user sees (visible text, ARIA), so the suite is a behavioural
  contract. The harness starts the server itself and waits for it.

`gleam test` runs against the **base seed** (no invoices), which keeps the financial tests
deterministic; `bin/reseed` layers a full demo (timesheets, 18 invoices across the lifecycle,
monthly payroll runs, a back-dated promotion that surfaces a payroll variance, and a
mid-month promotion that shows the payroll per-level breakdown) for the e2e suite and for
clicking around. Current state: **223 Gleam tests + 53 Playwright specs**.

## Running it

```sh
bin/up                # PG19 up + migrate + build the client + serve on http://localhost:8000
bin/seed-invoices     # layer the demo financials on demand (idempotent)
```

`bin/up` is idempotent and safe to re-run. The individual wrappers are there for running one
piece: `bin/db` (PG19 container), `bin/migrate`, `bin/build` (client bundle →
`server/priv/static`), `bin/serve`, `bin/test`, `bin/e2e`, `bin/lint-css`, `bin/squirrel`
(regenerate `sql.gleam`), `bin/erd` (regenerate the schema map). Connection settings come
from the environment with dev defaults matching `docker-compose.yml` (`TEMPO_DB_HOST`
127.0.0.1, `TEMPO_DB_PORT` 5434, name/user/password `tempo`, `TEMPO_DB_POOL_SIZE` 20).
