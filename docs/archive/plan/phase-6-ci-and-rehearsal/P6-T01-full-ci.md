---
id: P6-T01
phase: 6
title: Full CI (both tags)
status: done
depends_on: [P5-T04]
parallelizable_with: [P6-T03, P6-T04]
agent: workflow
---

# P6-T01 — Full CI (both tags)

## Objective
The complete pipeline: all Gleam tests plus the Playwright suite on **both** schema states.

## References
- `ARCHITECTURE.md` §10 (provisioning / CI)
- `DECISIONS.md` ADR-013

## Work
- [ ] Extend `.github/workflows/test.yml`: provision PG19 → `gleam test` (layers 1–4) → build client
      + start server → seed v1 + Playwright → apply migration → run the **same** Playwright again.
- [ ] Cache npm + Playwright browsers for speed.
- [ ] Fail the job if either Playwright pass is red.

## Acceptance
- CI green end to end, including both Playwright passes and the migration oracle.

## Notes
This is the gate that protects the live demo from regressions.

### Implementation (`.github/workflows/test.yml`)
Single `test` job on `ubuntu-latest`, PG19 as a `services.db` container
(`postgres:19beta1`, host port 5434, healthcheck on `pg_isready`). Steps, in order:

1. Toolchains — `setup-beam` (OTP 29 / Gleam 1.17.0) and `setup-node@v4` with
   `cache: npm` (npm download cache, keyed on `package-lock.json`).
2. `gleam run -m tempo/migrate` then `gleam test` then `gleam format --check src test`
   — applies 001-010 (final v2-split) and runs all 52 unit tests (layers 1-4) plus
   the migrate idempotency check.
3. `gleam run -m lustre/dev build client/app` (working-directory `client`) — builds
   the Lustre bundle into `priv/static` once, reused by both Playwright passes.
4. `gleam run -m tempo/oracle` — the migration oracle (1096-day board-equality gate);
   runs in isolation because it rebuilds the schema, and exits non-zero on any
   differing date. Leaves the DB at v2-split.
5. Cache Playwright browsers (`actions/cache` on `~/.cache/ms-playwright`, keyed on
   `package-lock.json`), `npm ci`, `playwright install --with-deps chromium`.
6. **Playwright pass 1 (v1-wide):** rebuild `public`, apply ONLY 001-003 via psql
   (recording each in `schema_migrations` exactly as the runner would), start the
   server, `npx playwright test`. Upload `playwright-report-v1-wide`.
7. **Playwright pass 2 (v2-split):** `gleam run -m tempo/migrate` (sees 001-003
   recorded, applies only 010) on the SAME data, then `npx playwright test` against
   the still-running server (it reads the DB live per request). Upload
   `playwright-report-v2-split`.

Either Playwright pass failing fails the job (non-zero exit; `playwright.config.js`
sets `forbidOnly` + `retries: 2` under `CI`). The v1-only seed is done with psql
rather than the runner because `tempo/migrate` always applies every pending file
(incl. 010); psql handles the dollar-quoted blocks in `003_seed.sql` natively, and
recording the three versions keeps the ledger consistent so pass 2's migrate applies
exactly 010. This is the same two-state staging the live demo uses (v1-wide for the
"before"/migration reveal, v2-split as the final).

### Locally verified (against the dev Docker PG19, port 5434)
Ran the workflow's exact command scripts in order on a freshly-reset schema:
- migrate from empty applies 001+002+003+010; `gleam test` = **52 passed**;
  `gleam format --check` clean.
- client build = **Build complete**.
- `gleam run -m tempo/oracle` = **ORACLE PASS: board identical for all 1096 dates**.
- v1-wide seed (psql 001-003) → server up → Playwright = **10 passed**.
- `gleam run -m tempo/migrate` (applies only 010) → Playwright = **10 passed**.
- DB left at v2-split (the documented end state).
YAML well-formedness + step ordering (pw-v1 → migrate → pw-v2, oracle before)
validated by parsing the file (19 steps, parses cleanly).

### Could NOT be executed locally
- The GitHub Actions workflow itself cannot run locally (no `act`/runner installed),
  so the CI-only mechanics are validated by faithful local equivalents, not by an
  actual Actions run: the `services.db` container provisioning, the `actions/cache`
  Playwright-browser cache and `setup-node` npm cache (hit/miss behaviour), the
  `setup-beam`/`setup-node` toolchain installs, `npm ci` + `playwright install
  --with-deps` (the runner already had deps + chromium), and the artifact uploads.
  The DB connection, migration sequencing, oracle, and both Playwright passes were
  all exercised directly. First green Actions run is the final confirmation of the
  runner-managed steps.
