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
gleam test                  # includes the DB connection smoke check
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

```sh
gleam run                   # start the Wisp server (serves API + static assets)
gleam test                  # run the test suite
```

### Client (Lustre SPA)

The repo is a **three-package workspace** (ADR-014): the root `tempo` server
package, a `shared/` package (the API contract — types + JSON codecs, compiled
for both targets), and a `client/` package (the Lustre SPA, JS target). Gleam
1.17 compiles a whole package per target with no per-module target exclusion, so
a single package cannot build the JS client: the server's Erlang-only modules
(pog/wisp/mist) would be type-checked for JS and fail. The split keeps the
client's dependency graph free of server code; both `client` and `tempo`
path-depend on `shared`.

The client is built from the `client/` package; its bundle is emitted into
`priv/static`, which Wisp serves under `/static`:

```sh
cd client && gleam run -m lustre/dev build client/app
```

Rebuild after changing `client/*` or `shared/*`, then `gleam run` from the repo
root (or refresh the browser) to serve the new bundle.

### End-to-end tests (Playwright)

Behaviour-driven browser tests live under `e2e/` — one spec per demo beat
(PRD §7): the slider/org board (`slider-board.spec.js`) and the my-timesheet
panel including the negative beat (`timesheet.spec.js`). They drive the **real
app** and assert only what the user sees, so the same suite passes *unmodified*
against both `v1-wide` and `v2-split` (see `ARCHITECTURE.md` §10.5).

First-time setup:

```sh
npm install                 # install @playwright/test
npx playwright install chromium
```

Run the suite — build the client, start the server on the v1-wide seed, then
run Playwright (it targets `http://127.0.0.1:8000` by default):

```sh
docker compose up -d                                      # PG19
gleam run -m tempo/migrate                                # schema + v1-wide seed
cd client && gleam run -m lustre/dev build client/app && cd ..
gleam run &                                               # serve on :8000
npx playwright test                                       # the e2e suite (chromium)
```

Point it at a different host/port with `TEMPO_BASE_URL`:

```sh
TEMPO_BASE_URL=http://127.0.0.1:8000 npx playwright test
```
