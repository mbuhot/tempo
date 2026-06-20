---
id: P0-T05
phase: 0
title: Playwright harness skeleton
status: done
depends_on: []
parallelizable_with: [P0-T01]
agent: workflow
---

# P0-T05 — Playwright harness skeleton

## Objective
Stand up the Playwright project so e2e tests can be written continuously from Phase 4 onward.

## References
- `ARCHITECTURE.md` §10.5 (e2e), §10 (determinism/CI)
- `DECISIONS.md` ADR-013

## Work
- [ ] `npm init` + `npm i -D @playwright/test`; `npx playwright install` (chromium).
- [ ] Add `playwright.config` pointing at a configurable `baseURL`.
- [ ] Add a trivial smoke spec (loads `baseURL`, asserts the page responds) — placeholder until P4.
- [ ] Add `.gitignore` entries for `node_modules/`, Playwright artifacts.
- [ ] Document `npx playwright test` in the run-book stub.

## Acceptance
- `npx playwright test` runs and the smoke spec passes against any served placeholder page.

## Notes
Tests will be behaviour-driven (assert what the user sees). No app behaviour exists yet — keep the
smoke spec minimal.
