"""High-signal nightly scenarios that also need commit-matched main-CI evidence."""
from __future__ import annotations

import pytest
from playwright.sync_api import expect

from nightly.test_tenant_contract import test_additional_tenant_resource_reads_require_membership as _tenant_reads
from pages import ResidentHome
from support.flutter import by_id

pytest_plugins = ["nightly.test_tenant_contract"]


@pytest.mark.core
@pytest.mark.covers("SC-01-04-04")
def test_issue_description_has_accessible_name(page, login_as):
    """Keep the issue-description accessible-name check in the main PR and master lane."""
    login_as("homeowner")
    ResidentHome(page).wait()
    by_id(page, "resident_action_requests").click()
    expect(page.get_by_label("Açıklama", exact=True)).to_be_visible()


@pytest.mark.core
@pytest.mark.covers("SC-10-01-03")
def test_additional_tenant_resource_reads_require_membership(api, stack, actors, two_sites):
    """Run the existing nightly tenant-resource contract in the commit-gated lane."""
    _tenant_reads(api, stack, actors, two_sites)
