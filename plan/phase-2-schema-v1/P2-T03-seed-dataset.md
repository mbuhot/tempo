---
id: P2-T03
phase: 2
title: Seed dataset (v1, deterministic)
status: todo
depends_on: [P2-T01]
parallelizable_with: [P2-T02]
agent: unassigned
---

# P2-T03 — Seed dataset (v1, deterministic)

## Objective
Build the single source-of-truth seed: deterministic, anchored to a fixed "now", engineered so every
demo beat and test has the data it needs.

## References
- `ARCHITECTURE.md` §7 (seed invariant), `PRD.md` §7 (beats), §9 (determinism)
- `DECISIONS.md` ADR-010, ADR-011

## Work
- [ ] `priv/migrations/00X_seed.sql` (or a seed module) with explicit ids/names/dates/rates — no
      factory sequences.
- [ ] Include data that exercises: a **promotion** (future-dated relative to seed "now"), a **leave**
      overlapping an allocation, a **rate-card change**, a **fractional split** (one engineer on two
      projects), and **cached-rate fragmentation** in `allocation` (for the P5 coalescing demo).
- [ ] Enforce the **seed invariant**: every `allocation.day_rate` equals `rate_card[level]` for the
      overlapping period.
- [ ] Pick and document the fixed seed "now" date used by UI/tests.

## Acceptance
- Seed loads cleanly; a check confirms the seed invariant holds for all allocation rows.

## Notes
This dataset is reused by P3 query tests, P4 Playwright, and the P5 oracle — keep it stable.
