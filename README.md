# tempo

A live-demo app showcasing **PostgreSQL 19 native temporal tables** (SQL:2011
application-time periods) through a consultancy staffing model, built with
Gleam, Squirrel, Wisp, and Lustre. See `docs/PRD.md` and `docs/ARCHITECTURE.md`.

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
`TEMPO_DB_POOL_SIZE` (20).

`TEMPO_DB_POOL_SIZE` is sized against PostgreSQL `max_connections` (100 on the
dev container): a single board tick fans out ~5 concurrent as-of queries, so 20
lets a few scrubs overlap without queueing while leaving headroom. Keep
`instances × pool_size + headroom ≤ max_connections`. When the pool is
saturated, a checkout times out and the API answers **503 Service Unavailable**
(retryable) rather than hanging or returning a 500.

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

### Schema: anchors + edit-grouped facts

Every entity is an **ID-only anchor** (`engineer`, `client`, `contract`,
`project`, `invoice`, `payroll_run` are bare `id` rows); all attributes live in
**fact tables** keyed to the anchor. Facts come in two temporal flavours, and the
read chosen per query:

- **Valid-time facts**, read **AS-OF** the slider date (period named for what it
  asserts: `employed_during`, `held_during`, `on_leave_during`, `allocated_during`,
  `term`, `active_during`, `effective_during`, `status_during`, `work_day`,
  `planned_during`) — the version in force on that date.
- **Latest-read facts** (descriptive / contact detail), period named
  `recorded_during`: append-only, the most-recently-effective row is current
  truth and older rows are history. Current value is exposed via the `*_current`
  views (`engineer_current`, `client_current`, `project_current`).

The new fact tables are `engineer_contact` / `engineer_banking` /
`engineer_emergency`, `client_profile`, `contract_terms`, `project_run`,
`project_profile`, `project_plan` (all of the above flavours), plus the immutable
1:1 `invoice_subject` and `payroll_period` (the latter carries the no-overlap
`EXCLUDE`). Writes flow through the command bus as temporal `Change`s
(`UpdateContactDetails`, `UpdateBankingDetails`, `UpdateEmergencyContact`,
`UpdateClientProfile`, `UpdateProjectProfile`, `UpdateProjectPlan`); `sign_contract`
/ `start_project` / `onboard_engineer` mint the anchor and open its founding fact
rows. The temporal containment chain is now
`contract_terms → project_run → allocation → timesheet` and
`employment → {engineer_role, leave, allocation}`, with `invoice_subject ⊂
project_run`. See `docs/SCHEMA.md` (regenerated from the live DB by `bin/erd`) for the
full table/relationship map.

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

`bin/build` does two things: it compiles the Lustre bundle to
`../server/priv/static/app.js`, then copies the CSS source. The CSS source lives
in `client/styles/` as plain-CSS component files (`base`, `slider`, `board`,
`timesheet`, `console`, `event-log`, `financials`) plus a central `theme.css` of
design tokens (a constrained t-shirt scale for spacing/type/sizes and a semantic
`--color-*` palette — every component references `var(--token)`), imported in
page order by `main.css`. `bin/build` copies `client/styles/` to
`server/priv/static/styles/`, which is a gitignored build artifact (like
`app.js`); `index.html` links `/static/styles/main.css`.

Rebuild after changing `client/*` (including `client/styles/*`) or `shared/*`,
then `cd server && gleam run` (or refresh the browser) to serve the new bundle.

### End-to-end tests (Playwright)

The Playwright harness is its own package under `e2e/` (`package.json`,
`playwright.config.js`, and one spec per UI surface): the slider/org board
(`slider-board.spec.js`), the my-timesheet panel including the negative beat
(`timesheet.spec.js`), the operations console + event-log panel
(`operations.spec.js`) — applying a `promote` and asserting the board re-renders
to the new level/rate and the event log gains the entry, plus a
containment-violating operation that surfaces a typed rejection to the user — and
the financials view (`financials.spec.js`): drafting then issuing an invoice and
watching its total land in the P&L revenue, with the invoice status read as-of the
slider date. They drive the **real app** and assert only what the user sees. The
read-model specs (slider/board and timesheet) assert only what the user sees; the
operations and financials specs exercise the write model (operations console +
`event_log` and the invoice/payroll tables).

The whole suite is **129 Gleam tests** (`cd server && gleam test`) **+ 14
Playwright specs** (across the four spec files above).

First-time setup (from `e2e/`):

```sh
cd e2e && npm install       # install @playwright/test
cd e2e && npx playwright install chromium
```

Run the suite — build the client, start the server on the migrated seed, then run
Playwright (it targets `http://127.0.0.1:8000` by default). The
operations spec applies a write and restores the seed afterward via `psql` (same
`TEMPO_DB_*` env-var defaults as the server), so `psql` must be on `PATH`:

```sh
docker compose up -d                                      # PG19 (repo root)
cd server && gleam run -m tempo/migrate                   # schema + seed
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
