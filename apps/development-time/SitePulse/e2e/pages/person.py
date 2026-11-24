"""Shared person picker and the owners & residents unit workspace (REQ-042).

Action, unit and registration pages have no name/phone/email inputs: a person is chosen
or created through `SpPersonField` -> `showSpPersonPicker` -> `SpPersonForm`.
"""
from __future__ import annotations

from playwright.sync_api import Page
from playwright.sync_api import TimeoutError as PlaywrightTimeoutError

from support.flutter import by_id, by_id_prefix, fill


class PersonPicker:
    """Chooses or creates the person card of one `SpPersonField` (its id is `field_id`)."""

    def __init__(self, page: Page, field_id: str):
        self.page = page
        self.field_id = field_id

    def _open(self) -> None:
        by_id(self.page, self.field_id).click()
        by_id(self.page, "sp_person_search").wait_for(timeout=10_000)

    def _chosen(self) -> None:
        by_id(self.page, f"{self.field_id}_card").wait_for(timeout=15_000)

    def create(self, full_name: str, phone: str = "", email: str = "", reuse_existing: bool = False) -> None:
        """Create a new card from the picker and choose it.

        With `reuse_existing`, a card the duplicate check offers for the typed data is chosen
        instead when there is one (the form refuses a second card with the same e-mail).
        """
        self._open()
        by_id(self.page, "sp_person_create").click()
        by_id(self.page, "person_form_name").wait_for(timeout=10_000)
        fill(self.page, "person_form_name", full_name)
        if phone:
            fill(self.page, "person_form_phone", phone)
        if email or phone:
            checking = by_id(self.page, "person_form_checking")
            candidate_any = by_id_prefix(self.page, "person_form_use_").first
            try:
                checking.or_(candidate_any).first.wait_for(timeout=1_500)
            except PlaywrightTimeoutError:
                pass
            checking.wait_for(state="detached", timeout=15_000)
        candidate = by_id_prefix(self.page, "person_form_use_").first
        if reuse_existing and candidate.count() > 0:
            candidate.click()
        else:
            by_id(self.page, "person_form_save").click()
        self._chosen()

    def choose(self, person_id: int | str, query: str) -> None:
        """Search for an existing card and choose it."""
        self._open()
        fill(self.page, "sp_person_search", query)
        result = by_id(self.page, f"sp_person_result_{person_id}")
        result.wait_for(timeout=10_000)
        result.click()
        self._chosen()


class UnitWorkspace:
    """The module's unit workspace, opened from a unit row on the residents tab."""

    def __init__(self, page: Page):
        self.page = page

    def open(self, unit_id: str) -> "UnitWorkspace":
        by_id(self.page, f"module_unit_actions_{unit_id}").click()
        by_id(self.page, "workspace_actions").wait_for(timeout=10_000)
        return self

    def action(self, unit_id: str, *names: str) -> str:
        """Tap the first of `names` the workspace offers for the unit; return its name.

        The action list builds rows lazily, so it is scrolled until a row exists.
        """
        rows = {name: by_id(self.page, f"workspace_action_{name}_{unit_id}") for name in names}
        self.page.mouse.move(640, 500)
        for _ in range(12):
            for name, row in rows.items():
                if row.count() > 0:
                    row.click()
                    return name
            self.page.mouse.wheel(0, 400)
            self.page.evaluate("() => new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r)))")
        raise AssertionError(f"unit {unit_id}: none of the workspace actions {names} is offered")

    def back(self) -> None:
        """Return from the workspace to the directory it was opened from."""
        button = by_id(self.page, "workspace_return_btn")
        try:
            # The button can lag behind a just-closed overlay (statement, dialog).
            button.wait_for(state="visible", timeout=5_000)
        except PlaywrightTimeoutError:
            return
        button.click()
        button.wait_for(state="detached", timeout=10_000)

    def close(self) -> None:
        """Leave the workspace and the module page, back to the residents tab."""
        self.back()
        module = by_id(self.page, "module_bottom_close_btn")
        if module.count() > 0:
            module.click()
            module.wait_for(state="detached", timeout=10_000)
