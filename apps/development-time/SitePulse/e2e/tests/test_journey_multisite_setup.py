"""Isolation checks for the stateful zero-to-multi-site journey."""
from __future__ import annotations

import pytest


@pytest.mark.covers("SC-13-26-01")
@pytest.mark.smoke
@pytest.mark.core
def test_onboarding_attempt_starts_with_an_empty_site_list(stack, api, actors):
    """Use the disposable E2E database, retaining no shared demo-site fixtures."""
    stack.reset_empty()

    assert stack.sql("SELECT COUNT(*) FROM sites WHERE deleted_at IS NULL;") == "0"
    assert stack.sql("SELECT COUNT(*) FROM sites WHERE slug IN ('begonya-sitesi', 'kardelen-rezidans');") == "0"

    saas = api.login(**actors["saas"])
    assert api.saas_sites(saas) == []


