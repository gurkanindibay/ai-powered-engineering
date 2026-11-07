from __future__ import annotations

from playwright.sync_api import Page

from support.flutter import by_id, by_id_prefix, fill, text_of


class SaasAdmin:
    def __init__(self, page: Page):
        self.page = page

    def wait(self) -> "SaasAdmin":
        by_id_prefix(self.page, "btn_edit_site_").first.wait_for(timeout=20_000)
        return self

    def site_ids(self) -> list[str]:
        return sorted(i.removeprefix("btn_edit_site_") for i in self.page.eval_on_selector_all(
            '[flt-semantics-identifier^="btn_edit_site_"]',
            "els => els.map(e => e.getAttribute('flt-semantics-identifier'))"))

    @property
    def must_change_password_banner(self):
        return by_id(self.page, "banner_must_change_password")

    def change_password(self, current: str, new: str) -> None:
        by_id(self.page, "btn_open_change_password").click()
        by_id(self.page, "change_password_current").wait_for(timeout=10_000)
        fill(self.page, "change_password_current", current)
        fill(self.page, "change_password_new", new)
        fill(self.page, "change_password_confirm", new)
        # Wait for the backend's answer, not just the UI: the banner can disappear before it is stored.
        with self.page.expect_response(lambda r: "/api/v1/auth/change-password" in r.url, timeout=15_000) as resp:
            by_id(self.page, "btn_submit_change_password").click()
        if resp.value.status != 200:
            raise AssertionError(f"change-password -> {resp.value.status}: {resp.value.text()[:300]}")

    def site_name(self, site_id: str) -> str:
        return text_of(by_id(self.page, f"site_card_name_{site_id}"))

    def edit_site(self, site_id: str, name: str, address: str, admin_phone: str) -> None:
        by_id(self.page, f"btn_edit_site_{site_id}").click()
        by_id(self.page, "edit_site_name_field").wait_for(timeout=10_000)
        fill(self.page, "edit_site_name_field", name)
        fill(self.page, "edit_site_address_field", address)
        fill(self.page, "edit_site_admin_phone_field", admin_phone)
        by_id(self.page, "btn_save_site_edit").click()
        by_id(self.page, "btn_save_site_edit").wait_for(state="detached", timeout=15_000)

    def delete_site(self, site_id: str) -> None:
        by_id(self.page, f"btn_delete_site_{site_id}").click()
        by_id(self.page, "btn_confirmation_confirm").click()

    def reset_admin_password(self, site_id: str) -> "SiteCredentials":
        by_id(self.page, f"btn_reset_admin_password_{site_id}").click()
        by_id(self.page, "btn_confirmation_confirm").click()
        return SiteCredentials(self.page).wait()

    def open_add_site(self) -> "AddSiteForm":
        by_id(self.page, "btn_open_add_site").click()
        return AddSiteForm(self.page).wait()


class AddSiteForm:
    """'Yeni Site / Kompleks Kaydet' full-screen form."""

    def __init__(self, page: Page):
        self.page = page

    def wait(self) -> "AddSiteForm":
        by_id(self.page, "add_site_name_field").wait_for(timeout=10_000)
        return self

    def fill(self, name: str, city: str, address: str, blocks: str, admin_name: str, admin_email: str,
             admin_phone: str) -> "AddSiteForm":
        for field, value in (("name", name), ("city", city), ("address", address), ("blocks", blocks),
                             ("admin_name", admin_name), ("admin_email", admin_email),
                             ("admin_phone", admin_phone)):
            fill(self.page, f"add_site_{field}_field", value)
        return self

    def save(self) -> "SiteCredentials":
        by_id(self.page, "btn_save_new_site").click()
        return SiteCredentials(self.page).wait()


class SiteCredentials:
    """Dialog shown after onboarding: the new manager's temporary password."""

    def __init__(self, page: Page):
        self.page = page

    def wait(self) -> "SiteCredentials":
        by_id(self.page, "site_credentials_password").wait_for(timeout=15_000)
        return self

    def password(self) -> str:
        return text_of(by_id(self.page, "site_credentials_password"))

    def close(self) -> None:
        by_id(self.page, "btn_close_site_credentials").click()
