-- event_log_append.sql — append one provenance row (§5a, §4, ADR-021).
--
-- `dispatch` writes exactly one of these per applied command, in the same
-- transaction as the temporal fact writes, so facts and journal commit together
-- or not at all. `occurred_at` defaults to now() (SYSTEM time). The whole row is
-- returned (id doubles as the order applied; occurred_at/payload rendered to text
-- at the boundary) so the caller maps it straight to the shared read Event —
-- never a guessed "newest row". The command is re-encoded via the shared codecs
-- as `payload`, cast to jsonb at the boundary.
-- $1 = actor, $2 = operation tag, $3 = summary, $4 = payload (json text).
INSERT INTO event_log (actor, operation, summary, payload)
VALUES ($1, $2, $3, $4::jsonb)
RETURNING id, occurred_at::text, actor, operation, summary, payload::text;
