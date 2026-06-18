# tempo

A live-demo app showcasing **PostgreSQL 19 native temporal tables** (SQL:2011
application-time periods) through a consultancy staffing model, built with
Gleam, Squirrel, Wisp, and Lustre. See `PRD.md` and `ARCHITECTURE.md`.

## Run-book

### Quick start

One command brings the whole stack up and runs it — starts PG19 and waits for it,
applies pending migrations, builds the client bundle, then serves on
**http://localhost:8000** (Ctrl-C stops the server; the DB container keeps running):

```sh
bin/up
```

It is idempotent — safe to re-run. The individual steps below are for when you want
to run a single piece (e.g. just the server, or just the tests).

On a freshly-migrated DB the financial screens are empty. To populate a demo set —
one issued invoice + one draft invoice + a June payroll run — on demand, run:

```sh
bin/seed-invoices            # populate demo financials; idempotent, NOT run by bin/up
```

It is idempotent (skips if already populated) and deliberately left out of `bin/up`,
so a freshly-migrated DB stays test-clean until you ask for the demo data.

### Database (PostgreSQL 19)

The demo requires **PostgreSQL 19** (for `WITHOUT OVERLAPS`, `PERIOD` foreign
keys, and `FOR PORTION OF`). A local PG ≤ 18 will not work, so PG19 runs in
Docker. Start it with one command:

```sh
docker compose up -d        # PG19 on host port 5434 (db/user/password: tempo)
```

Then verify the pool connects (runs a `SELECT 1` smoke check):

```sh
cd server && gleam test     # includes the DB connection smoke check
```

Stop / reset the database:

```sh
docker compose down         # stop, keep data
docker compose down -v      # stop and wipe the data volume
```

Connection settings come from the environment (defaults match the compose
file): `TEMPO_DB_HOST` (127.0.0.1), `TEMPO_DB_PORT` (5434), `TEMPO_DB_NAME`
(tempo), `TEMPO_DB_USER` (tempo), `TEMPO_DB_PASSWORD` (tempo),
`TEMPO_DB_POOL_SIZE` (10).

### Application

The Gleam server package lives in `server/` (it path-depends on `../shared`), so
run all `gleam` commands from there. The repo root also ships thin `bin/` wrappers
that `cd` into the right package for you:

```sh
cd server && gleam run       # start the Wisp server (serves API + static assets)
cd server && gleam test      # run the test suite

# or, from the repo root, via the bin/ scripts:
bin/serve                    # cd server && gleam run
bin/test                     # cd server && gleam test && gleam format --check src test
```

### Migration oracle (board provably identical across v1 → v2)

The standout automated check (ARCHITECTURE.md §7, §10.2): it seeds a **fresh
v1-wide** database, snapshots the org board for **every day** of the seed span
(2024-01-01 .. 2026-12-31, 1096 dates), applies the `010_split_allocation`
migration, re-snapshots, and asserts the user-visible board
(engineer / level / project / client / fraction / charge rate) is **identical
for every date** — failing loudly with the first differing date. It compares the
user-visible columns only: the engagement window (`valid_from`/`valid_to`) is
expected to change, because coalescing fragmented allocations into whole
engagements is the whole point of the migration, and the client never renders it.

It is **not** part of `gleam test`: it drops and rebuilds the `public` schema,
which would tear down the seed the rest of the suite relies on. Run it on its own.
It rebuilds a fresh pre-migration schema and applies only `001`–`003` + `010`, so
it leaves the dev DB at the **v2-split** schema but **without** the later
`011_event_log` table (it stops at the migration reveal). To get back to the full
demo state — including the event log the operations console writes to — re-run
`gleam run -m tempo/migrate` afterward, which applies the pending `011`:

```sh
docker compose up -d                                      # PG19
cd server && gleam run -m tempo/oracle                    # exits 0 on PASS, non-zero on a mismatch
cd server && gleam run -m tempo/migrate                   # re-apply 011_event_log → full demo state
# or: bin/oracle then bin/migrate
```

### Client (Lustre SPA)

The repo is a **four-package layout** (ADR-014): a `server/` package (the Gleam
Wisp server, Erlang target), a `shared/` package (the API contract — types + JSON
codecs, compiled for both targets), a `client/` package (the Lustre SPA, JS
target), and an `e2e/` package (the Playwright harness, Node). Gleam 1.17 compiles
a whole package per target with no per-module target exclusion, so a single
package cannot build the JS client: the server's Erlang-only modules
(pog/wisp/mist) would be type-checked for JS and fail. The split keeps the
client's dependency graph free of server code; both `client` and `server`
path-depend on `shared`.

The client is built from the `client/` package; its bundle is emitted into
`../server/priv/static` (the client's `[tools.lustre.build] outdir`), which Wisp
serves under `/static`:

```sh
cd client && gleam run -m lustre/dev build client/app
# or: bin/build
```

Rebuild after changing `client/*` or `shared/*`, then `cd server && gleam run`
(or refresh the browser) to serve the new bundle.

### End-to-end tests (Playwright)

The Playwright harness is its own package under `e2e/` (`package.json`,
`playwright.config.js`, and one spec per UI surface, exercising the PRD §7
functional requirements): the slider/org board (`slider-board.spec.js`, FR-1–FR-4),
the my-timesheet panel including the negative beat (`timesheet.spec.js`, FR-5,
FR-7), and the operations console + event-log panel (`operations.spec.js`, FR-9,
FR-11) — applying a `promote` and asserting the board re-renders to the new
level/rate and the event log gains the entry, plus a containment-violating
operation that surfaces a typed rejection to the user. They drive the **real app**
and assert only what the user sees. The read-model specs (slider/board and
timesheet) assert nothing tag-specific, so they pass *unmodified* against both
`v1-wide` and `v2-split` (see `ARCHITECTURE.md` §10.5); the operations spec
exercises the v2 write model (operations console + `event_log`) and so targets
`v2-split`.

First-time setup (from `e2e/`):

```sh
cd e2e && npm install       # install @playwright/test
cd e2e && npx playwright install chromium
```

Run the suite — build the client, start the server on the migrated (v2-split)
seed, then run Playwright (it targets `http://127.0.0.1:8000` by default). The
operations spec applies a write and restores the seed afterward via `psql` (same
`TEMPO_DB_*` env-var defaults as the server), so `psql` must be on `PATH`:

```sh
docker compose up -d                                      # PG19 (repo root)
cd server && gleam run -m tempo/migrate                   # schema + seed, ending at v2-split
cd client && gleam run -m lustre/dev build client/app     # bundle → ../server/priv/static
cd server && gleam run &                                  # serve on :8000
cd e2e && npx playwright test                             # the e2e suite (chromium)
```

Or use the `bin/` wrappers from the repo root: `bin/db`, `bin/migrate`,
`bin/build`, `bin/serve` (background it), then `bin/e2e`. Point Playwright at a
different host/port with `TEMPO_BASE_URL`:

```sh
cd e2e && TEMPO_BASE_URL=http://127.0.0.1:8000 npx playwright test
```
