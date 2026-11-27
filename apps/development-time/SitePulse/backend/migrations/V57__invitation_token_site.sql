-- V57: invitations record their site (issue #542).
--
-- `db::save_invitation_token` never wrote `site_id`, although the column has a
-- foreign key to `sites`, an index and the `tenant_isolation` policy. The rows
-- were therefore unreachable from any tenant-bound read and survived a site
-- purge that deletes `invitation_tokens WHERE site_id = $1`.
--
-- The insert writes the site from now on; this backfills rows created before it.
-- A token without a unit cannot be attributed and stays NULL: the registration
-- path refuses such a row because it joins the unit and site.

UPDATE invitation_tokens AS token
SET site_id = unit.site_id
FROM units AS unit
WHERE token.unit_id = unit.id
  AND token.site_id IS NULL;
