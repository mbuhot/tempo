-- engineer_lock.sql — take a row lock on the required attendees' engineer rows
-- before re-checking availability inside the booking transaction: the finder's
-- suggestion was computed seconds-to-minutes earlier and may be stale by the time
-- a human books it, so the write path must serialize against any other write
-- racing the same attendee rather than trust a bare re-check under READ COMMITTED
-- (write-skew: two concurrent bookings could each see the OLD committed state and
-- both pass). Always acquired in ascending id order (ORDER BY id) so two bookings
-- sharing attendees never lock in opposite orders and deadlock. $1 = required
-- engineer ids (comma-separated text).
SELECT id FROM engineer WHERE id = ANY(string_to_array($1, ',')::bigint[]) ORDER BY id FOR UPDATE;
