-- Preserve the debtor who held title or occupancy when the liability was accrued.
-- A recorded accrual run supplies its actual local date. Older rows without a run
-- use the first day of their canonical billing period; due_date is only the later
-- collection deadline and can fall after a title or occupancy transition.
-- Rows without a matching historical relationship or usable period stay unassigned.
WITH due_accrual_dates AS (
    SELECT d.id,
           COALESCE(
               (
                   SELECT MIN((run.created_at AT TIME ZONE COALESCE(s.timezone, 'Europe/Istanbul'))::date)
                   FROM dues_accrual_runs AS run
                   JOIN units AS u ON u.id = d.unit_id
                   JOIN sites AS s ON s.id = u.site_id
                   WHERE run.site_id = u.site_id
                     AND run.period_key = d.period_key
               ),
               CASE
                   WHEN d.period_key ~ '^[0-9]{4}-(0[1-9]|1[0-2])$'
                   THEN to_date(d.period_key || '-01', 'YYYY-MM-DD')
                   ELSE NULL
               END
           ) AS accrued_on
    FROM dues_liabilities AS d
)
UPDATE dues_liabilities AS d
SET liable_person_id = CASE
    WHEN d.debtor_type = 'OWNER' THEN (
        SELECT ownership.person_id
        FROM unit_ownerships AS ownership
        WHERE ownership.unit_id = d.unit_id
          AND ownership.start_date <= dates.accrued_on
          AND (ownership.end_date IS NULL OR ownership.end_date >= dates.accrued_on)
        ORDER BY ownership.start_date DESC, ownership.id DESC
        LIMIT 1
    )
    ELSE COALESCE(
        (SELECT occupancy.person_id
         FROM unit_occupancies AS occupancy
         WHERE occupancy.id = d.occupancy_id
           AND occupancy.occupancy_type = 'TENANT'
           AND occupancy.start_date <= dates.accrued_on
           AND (occupancy.end_date IS NULL OR occupancy.end_date >= dates.accrued_on)),
        (SELECT occupancy.person_id
         FROM unit_occupancies AS occupancy
         WHERE occupancy.unit_id = d.unit_id
           AND occupancy.occupancy_type = 'TENANT'
           AND occupancy.start_date <= dates.accrued_on
           AND (occupancy.end_date IS NULL OR occupancy.end_date >= dates.accrued_on)
         ORDER BY occupancy.start_date DESC, occupancy.id DESC
         LIMIT 1)
    )
END
FROM due_accrual_dates AS dates
WHERE d.id = dates.id
  AND d.liable_person_id IS NULL;
