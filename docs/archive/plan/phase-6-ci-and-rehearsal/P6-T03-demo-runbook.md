---
id: P6-T03
phase: 6
title: Demo run-book + clean-checkout dry run
status: done
depends_on: [P5-T04]
parallelizable_with: [P6-T01, P6-T04]
agent: workflow
---

# P6-T03 — Demo run-book + clean-checkout dry run

## Objective
A step-by-step run-book mapping each of the 7 beats to concrete actions, validated by a from-scratch
dry run.

## References
- `PRD.md` §7 (beats), §9 (success criteria)

## Work
- [ ] Write `RUNBOOK.md`: prerequisites (PG19 up), start commands, and the exact click/scrub steps
      for beats 1–7, including the `git checkout v2-split` + migrate step for beat 6.
- [ ] Note the fixed seed "now" and the specific dates/engineers used in each beat.
- [ ] Do a clean-checkout dry run on the talk machine profile; fix anything that snags.

## Acceptance
- A fresh clone can reproduce all 7 beats by following `RUNBOOK.md`.

## Notes
This is the anti-"it broke live" insurance; rehearse the checkout/migrate timing.
