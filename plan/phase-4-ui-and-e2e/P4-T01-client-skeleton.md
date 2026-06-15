---
id: P4-T01
phase: 4
title: Client skeleton + build pipeline
status: done
depends_on: [P3-T02, P3-T05]
parallelizable_with: []
agent: claude
---

# P4-T01 — Client skeleton + build pipeline

## Objective
Get a minimal Lustre app building to `priv/static` and served by Wisp, importing the shared types.

## References
- `ARCHITECTURE.md` §3, §9
- `DECISIONS.md` ADR-005, ADR-014

## Work
- [x] `client/src/client/app.gleam` — minimal Lustre app (model/update/view) that fetches
      `GET /api/board` for the seed "now" and lists engineers.
- [x] Build via `cd client && gleam run -m lustre/dev build client/app` → `priv/static`; add `index.html`.
- [x] Confirm Wisp serves it and the page shows live data.
- [x] Document the build command in the run-book stub.

## Acceptance
- Loading the served page shows board rows decoded from the API via shared codecs.

## Notes
Client must import only `shared/*`. This unblocks T02/T03 view work.

Carried from Phase 1: `lustre/dev build` emits the bundle to `./dist` (gitignored), not
`priv/static`. Wire the build to output into `priv/static` (or point Wisp's static serving at the
build output) so the served page and the bundle agree.

## RESOLUTION (P4)

The original single-package layout could not bundle the client: `lustre/dev build` runs
`gleam build --target javascript`, which type-checks the whole package for JS — including the
Erlang-only server subtree (`pog`/`wisp`/`mist`/`gleam_otp` and the Squirrel-generated
`sql.gleam`) — and failed with "Unsupported target" errors. Gleam 1.17 compiles a whole
package per target with no per-module target exclusion, so import discipline alone (the
ADR-005 assumption) could not keep the JS build clean.

**Resolved by the three-package split (ADR-014).** The workspace is now the root `tempo`
server package plus two siblings: `shared/` (the API contract — `shared/types` + `shared/codecs`,
target-agnostic, compiles for both Erlang and JS) and `client/` (the Lustre SPA at
`client/src/client/app.gleam`, JS target). Both `tempo` and `client` path-depend on `shared`
(`{ path = "..." }`); the client never depends on server code, so its JS dependency graph is
clean and the bundle builds. The client is built with
`cd client && gleam run -m lustre/dev build client/app`, emitting `app.js` into `priv/static`
(served by Wisp under `/static`; the hand-written `priv/static/index.html` loads it). The
earlier `client_build/` symlink stopgap was removed as non-portable. See `ARCHITECTURE.md` §3
and `DECISIONS.md` ADR-014.
