# tempo

A live-demo app showcasing **PostgreSQL 19 native temporal tables** (SQL:2011
application-time periods) through a consultancy staffing model, built with
Gleam, Squirrel, Wisp, and Lustre. See `PRD.md` and `ARCHITECTURE.md`.

## Run-book

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
which would tear down the seed the rest of the suite relies on. Run it on its own
(it leaves the dev DB migrated to **v2-split**, the same end state as
`gleam run -m tempo/migrate`):

```sh
docker compose up -d                                      # PG19
cd server && gleam run -m tempo/oracle                    # exits 0 on PASS, non-zero on a mismatch
# or: bin/oracle
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
`playwright.config.js`, and one spec per demo beat, PRD §7): the slider/org board
(`slider-board.spec.js`) and the my-timesheet panel including the negative beat
(`timesheet.spec.js`). They drive the **real app** and assert only what the user
sees, so the same suite passes *unmodified* against both `v1-wide` and `v2-split`
(see `ARCHITECTURE.md` §10.5).

First-time setup (from `e2e/`):

```sh
cd e2e && npm install       # install @playwright/test
cd e2e && npx playwright install chromium
```

Run the suite — build the client, start the server on the v1-wide seed, then
run Playwright (it targets `http://127.0.0.1:8000` by default):

```sh
docker compose up -d                                      # PG19 (repo root)
cd server && gleam run -m tempo/migrate                   # schema + v1-wide seed
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
