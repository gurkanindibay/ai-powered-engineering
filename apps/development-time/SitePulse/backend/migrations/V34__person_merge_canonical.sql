-- Person merge: readers follow a merge tombstone to the current card without the
-- append-only payment ledger being rewritten.

-- The card a person ID resolves to today. A merged ID follows merged_into_person_id;
-- the walk is bounded so a corrupt cycle cannot loop forever (the self-merge CHECK
-- and the merge service prevent cycles).
CREATE OR REPLACE FUNCTION sp_canonical_person(start_id BIGINT)
RETURNS BIGINT
LANGUAGE SQL
STABLE
AS $$
    WITH RECURSIVE chain(id, next_id, depth) AS (
        SELECT p.id, p.merged_into_person_id, 0 FROM persons p WHERE p.id = start_id
        UNION ALL
        SELECT p.id, p.merged_into_person_id, c.depth + 1
        FROM chain c JOIN persons p ON p.id = c.next_id
        WHERE c.depth < 16
    )
    SELECT id FROM chain WHERE next_id IS NULL ORDER BY depth DESC LIMIT 1
$$;

CREATE INDEX IF NOT EXISTS idx_occupancy_members_occupancy_person
    ON occupancy_members (occupancy_id, person_id) WHERE person_id IS NOT NULL;
