from __future__ import annotations

from playwright.sync_api import Page

from support.flutter import by_id


class Shell:
    """Elements shared by every logged-in screen: app bar and navigation.

    Navigation is a bottom bar on phones and a rail from 840 dp; both tag each
    destination with `nav_<key>`. Profile is not a destination: it opens from
    the avatar (`btn_open_profile`), which also holds theme and logout.
    """

    NAV = ("home", "dues", "residents", "my_flat", "sites")

    def __init__(self, page: Page):
        self.page = page

    def nav(self, key: str) -> None:
        assert key in self.NAV, key
        by_id(self.page, f"nav_{key}").first.click()

    def logout(self) -> None:
        """Avatar -> profile sheet -> 'Çıkış Yap' -> confirm."""
        self.open_profile().logout()

    def open_profile(self) -> "ProfileSheet":
        by_id(self.page, "btn_open_profile").click()
        by_id(self.page, "btn_logout").wait_for(timeout=10_000)
        return ProfileSheet(self.page)


class ProfileSheet:
    """'Profil & Rol Yönetimi' full-screen sheet."""

    def __init__(self, page: Page):
        self.page = page

    def change_password(self, current: str, new: str) -> None:
        from support.flutter import fill
        by_id(self.page, "btn_change_password_sheet").click()
        by_id(self.page, "profile_change_password_current").wait_for(timeout=10_000)
        fill(self.page, "profile_change_password_current", current)
        fill(self.page, "profile_change_password_new", new)
        fill(self.page, "profile_change_password_confirm", new)
        by_id(self.page, "btn_submit_profile_change_password").click()
        by_id(self.page, "btn_submit_profile_change_password").wait_for(state="detached", timeout=15_000)

    @property
    def theme_toggle(self):
        """Carries 'theme:dark' / 'theme:light' in E2E builds."""
        return by_id(self.page, "btn_profile_toggle_theme")

    def logout(self, confirm: bool = True) -> None:
        by_id(self.page, "btn_logout").click()
        by_id(self.page, "btn_confirm_logout").wait_for(timeout=10_000)
        by_id(self.page, "btn_confirm_logout" if confirm else "btn_confirm_cancel").click()
