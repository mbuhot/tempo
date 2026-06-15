---
id: P4-T01
phase: 4
title: Client skeleton + build pipeline
status: todo
depends_on: [P3-T02, P3-T05]
parallelizable_with: []
agent: unassigned
---

# P4-T01 — Client skeleton + build pipeline

## Objective
Get a minimal Lustre app building to `priv/static` and served by Wisp, importing the shared types.

## References
- `ARCHITECTURE.md` §3, §9
- `DECISIONS.md` ADR-005

## Work
- [ ] `src/tempo/client/app.gleam` — minimal Lustre app (model/update/view) that fetches
      `GET /api/board` for the seed "now" and lists engineers.
- [ ] Build via `gleam run -m lustre/dev build tempo/client/app` → `priv/static`; add `index.html`.
- [ ] Confirm Wisp serves it and the page shows live data.
- [ ] Document the build command in the run-book stub.

## Acceptance
- Loading the served page shows board rows decoded from the API via shared codecs.

## Notes
Client must import only `shared/*`. This unblocks T02/T03 view work.
