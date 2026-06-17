-- 011_event_log.sql — the append-only provenance journal (ARCHITECTURE.md §4, ADR-021).
--
-- One row per applied operation, recording SYSTEM-time provenance *beside* the
-- facts: who did what, when. It never references and is never referenced by the
-- fact tables (no FKs in or out), so it constrains and contaminates nothing —
-- the model stays valid-time only (ADR-021); this is the cheap, honest sliver of
-- the system-time axis ("what did we do, and when?", not "what did we believe on
-- date X?").
--
-- Two clocks are explicit: `occurred_at` is the real wall clock (default now()),
-- while valid-time "now" is the fixed seed date. The identity `id` doubles as the
-- order in which operations were applied.
CREATE TABLE event_log (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,  -- also the order applied
  occurred_at timestamptz NOT NULL DEFAULT now(),  -- SYSTEM time: the real wall clock
  actor       text  NOT NULL,                      -- who applied it (nominal; no auth)
  operation   text  NOT NULL,                      -- command tag: 'promote', 'revise_rate_card', …
  summary     text  NOT NULL,                      -- human-readable description
  payload     jsonb NOT NULL                       -- the command's parameters (shared codecs)
);
