-- focus_block_delete.sql — drop a focus block its claimed owner holds. $1 focus_block_id,
-- $2 engineer_id. RETURNING gates a missing or foreign block.
DELETE FROM focus_block WHERE id = $1 AND engineer_id = $2 RETURNING id;
