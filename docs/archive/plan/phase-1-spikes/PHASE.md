---
id: P1
title: Spikes (de-risking)
type: phase
depends_on_phases: [P0]
---

# Phase 1 — Spikes (de-risking)

> Static phase overview. Live status is in each task file's frontmatter, not here.

## Goal

Resolve the four unknowns that could invalidate the design before we build on them
(`ARCHITECTURE.md` §11). Each spike is a throwaway experiment whose **finding is recorded in its task
file**; if a spike fails, update the relevant ADR / design doc and adjust downstream tasks.

## Tasks

| Task | Title | Parallelizable |
|---|---|---|
| P1-T01 | PG19 temporal DDL works | all parallel |
| P1-T02 | Squirrel ↔ `daterange` decomposition | all parallel |
| P1-T03 | Squirrel ↔ `FOR PORTION OF` | all parallel |
| P1-T04 | Temporal upsert for timesheet | all parallel |

All four are independent and may run concurrently.

## Exit criteria

- Each spike has a recorded **finding** (works as designed / needs the documented fallback).
- Any required design change is reflected in `ARCHITECTURE.md` / `DECISIONS.md`.
