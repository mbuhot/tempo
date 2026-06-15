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

### End-to-end tests (Playwright)

Behaviour-driven browser tests live under `e2e/` (one spec per demo beat from
Phase 4 onward; for now a single placeholder smoke spec). First-time setup:

```sh
npm install                 # install @playwright/test + http-server
npx playwright install chromium
```

Run the suite:

```sh
npx playwright test         # runs the e2e suite (chromium)
```

By default Playwright serves a static placeholder page and tests against it, so
the suite is self-contained. Point it at a running app by setting `baseURL`:

```sh
TEMPO_BASE_URL=http://127.0.0.1:8000 npx playwright test
```

The same suite is intended to pass *unmodified* against both `v1-wide` and
`v2-split` (see `ARCHITECTURE.md` §10.5) once the app is built.
