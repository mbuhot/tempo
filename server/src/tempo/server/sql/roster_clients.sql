-- roster_clients.sql — every client, by name.
--
-- The client-directory slice the operations console offers as a name <select>
-- (SignContract carries the client by NAME). A client is a durable identity —
-- it has no validity window — so this is NOT date-filtered: every client is
-- always selectable, id + name, ordered by name for a stable dropdown.
--
-- The id comes from the `client` ANCHOR (provably NOT NULL); the NAME, which left
-- the anchor for the edit-grouped client_profile fact, is read through the
-- `client_current` view (latest profile per client). The INNER JOIN means a
-- client with no profile row is omitted (every seeded client has one). coalesce
-- keeps the name column NOT NULL through the view boundary; it is never actually
-- null (the join is on a NOT NULL profile column).
SELECT client.id, coalesce(cc.name, '') AS name
FROM client
JOIN client_current cc ON cc.id = client.id
ORDER BY name;
