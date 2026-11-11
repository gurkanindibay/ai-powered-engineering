ALTER TABLE notifications
    DROP CONSTRAINT IF EXISTS chk_notification_category;

ALTER TABLE notifications
    ADD CONSTRAINT chk_notification_category CHECK (
        category IN (
            'DEBT_REMINDER', 'DEBT_NOTICE', 'PAYMENT', 'AUTOPAY', 'PLAN',
            'BUDGET', 'COLLECTION', 'SYSTEM', 'ANNOUNCEMENT'
        )
    );
