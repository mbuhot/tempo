---
id: P0-T01
phase: 0
title: Add Gleam dependencies
status: done
depends_on: []
parallelizable_with: [P0-T03, P0-T05]
agent: workflow
---

# P0-T01 — Add Gleam dependencies

## Objective
Add the runtime and dev dependencies the project needs, using `gleam add` (never hand-edit
`gleam.toml` versions).

## References
- `ARCHITECTURE.md` §1 (stack), §9 (build & run)
- `CLAUDE.md` — Gleam Dependencies

## Work
- [ ] `gleam add` the web/runtime deps: `wisp`, `mist` (or the Wisp-recommended server), `pog`,
      `lustre`.
- [ ] `gleam add` the tooling deps for codegen/build: `squirrel`, `lustre_dev_tools` (dev).
- [ ] Add `gleam_json` and `gleam_stdlib` decode helpers if not transitively present.
- [ ] Confirm `gleam build` resolves and compiles.

## Acceptance
- `gleam.toml` lists the deps with `gleam add`-selected versions; `gleam build` is green.

## Notes
Pick the currently-recommended Wisp HTTP server adapter. Keep `shared`-target-safe deps separate in
mind for T02.
