-- meeting_create.sql — mint a new meeting identity row, returning its id.
INSERT INTO meeting DEFAULT VALUES RETURNING id;
