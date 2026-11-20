-- Preserve the debtor who held the title or occupancy when the liability fell due.
-- Rows without a matching historical relationship stay unassigned instead of being
-- attributed to whoever happens to own or rent the unit today.
UPDATE dues_liabilities AS d
SET liable_person_id = CASE
    WHEN d.debtor_type = 'OWNER' THEN (
        SELECT ownership.person_id
        FROM unit_ownerships AS ownership
        WHERE ownership.unit_id = d.unit_id
          AND ownership.start_date <= d.due_date
          AND (ownership.end_date IS NULL OR ownership.end_date >= d.due_date)
        ORDER BY ownership.start_date DESC, ownership.id DESC
        LIMIT 1
    )
    ELSE COALESCE(
        (SELECT occupancy.person_id
         FROM unit_occupancies AS occupancy
         WHERE occupancy.id = d.occupancy_id
           AND occupancy.occupancy_type = 'TENANT'),
        (SELECT occupancy.person_id
         FROM unit_occupancies AS occupancy
         WHERE occupancy.unit_id = d.unit_id
           AND occupancy.occupancy_type = 'TENANT'
           AND occupancy.start_date <= d.due_date
           AND (occupancy.end_date IS NULL OR occupancy.end_date >= d.due_date)
         ORDER BY occupancy.start_date DESC, occupancy.id DESC
         LIMIT 1)
    )
END
WHERE d.liable_person_id IS NULL;
