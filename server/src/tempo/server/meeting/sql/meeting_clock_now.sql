-- meeting_clock_now.sql — the real wall-clock instant for a booking transition,
-- rendered to text at the boundary. `clock_timestamp()`, not `now()`: `now()` is frozen
-- at transaction start, so a close-then-open within one transaction would stamp both
-- halves with the identical instant.
SELECT clock_timestamp()::text AS at;
