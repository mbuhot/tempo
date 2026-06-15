---
id: P0-T02
phase: 0
title: Module structure (shared/server/client)
status: todo
depends_on: [P0-T01]
parallelizable_with: []
agent: unassigned
---

# P0-T02 — Module structure (shared/server/client)

## Objective
Create the dual-target module layout so server (Erlang), client (JS), and shared (both) code stay
cleanly separated.

## References
- `ARCHITECTURE.md` §3 (project structure), §2 (type flow)

## Work
- [ ] Create `src/tempo/shared/`, `src/tempo/server/`, `src/tempo/client/` with placeholder modules
      stubbed using `todo`.
- [ ] Keep `src/tempo.gleam` as the server entrypoint.
- [ ] Add a one-line module-doc header to each placeholder stating its target (both / Erlang / JS).
- [ ] Verify the client module graph imports only `shared/*` (no `server/*`).

## Acceptance
- `gleam build` (Erlang) compiles all modules; the intended client entry compiles for JS without
  pulling server-only deps.

## Notes
`shared` must be target-agnostic — no pog/wisp/erlang externals. This boundary is load-bearing for
the whole build.
