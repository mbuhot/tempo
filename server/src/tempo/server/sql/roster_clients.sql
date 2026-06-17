-- roster_clients.sql — every client, by name.
--
-- The client-directory slice the operations console offers as a name <select>
-- (SignContract carries the client by NAME). A client is a durable identity —
-- it has no validity window — so this is NOT date-filtered: every client is
-- always selectable, id + name, ordered by name for a stable dropdown.
SELECT id, name
FROM client
ORDER BY name;
