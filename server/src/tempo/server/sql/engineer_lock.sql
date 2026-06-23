-- engineer_lock.sql — take a row lock on the engineer anchor before reading the
-- leave balance, so the take_leave read-modify-write is serialized per engineer.
--
-- Under READ COMMITTED two concurrent leave requests can otherwise both read the
-- same balance and both commit (issue #2: over-grant) — the leave invariant has no
-- database backstop. Locking the anchor with `FOR UPDATE` makes the second request
-- block until the first commits, then re-read the now-reduced balance and be
-- rejected as InsufficientLeaveBalance. $1 = engineer_id.
SELECT id FROM engineer WHERE id = $1 FOR UPDATE;
