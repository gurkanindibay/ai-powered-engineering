"""SC-13-05-10: partial Excel import in the isolated F1 manager journey."""
from __future__ import annotations

import pytest

from support.bank_files import DEFAULT_RESIDENT_IMPORT_COLUMNS, resident_import_xlsx
from support.flutter import by_id, text_of
from support.journey_gui import journey_site, open_people_directory, sign_in_manager


def _import_rows() -> list[list[str]]:
    rows = [DEFAULT_RESIDENT_IMPORT_COLUMNS]
    for number in range(1, 6):
        rows.append([
            "B Blok", str(number), "1", f"Excel Partial Resident {number}",
            f"excel.partial.{number}@example.test", f"0532 700 20 {number:02d}",
            "10", "1.250,00", "evet", "", "", "",
        ])
    rows.append([
        "B Blok", "6", "2", "Excel Invalid Resident", "not-an-email",
        "0532 700 20 06", "10", "1.250,00", "evet", "", "", "",
    ])
    return rows


@pytest.mark.covers("SC-13-05-10")
@pytest.mark.core
@pytest.mark.role_manager
def test_journey_partial_excel_import_keeps_valid_rows_and_shows_invalid_row(
    request, api, actors, stack, page, login_page, tmp_path
):
    workbook = tmp_path / "partial-resident-import.xlsx"
    resident_import_xlsx(rows=_import_rows(), path=workbook)

    with journey_site(request, api, actors, stack, "F1") as fixture:
        sign_in_manager(page, login_page, fixture)
        open_people_directory(page)
        by_id(page, "people_import_btn").click()
        by_id(page, "person_import_pick_btn").wait_for(timeout=10_000)

        with page.expect_file_chooser() as chooser_info:
            by_id(page, "person_import_pick_btn").click()
        chooser_info.value.set_files(str(workbook))

        by_id(page, "person_import_check_btn").click()
        invalid_row = by_id(page, "person_import_row_7")
        invalid_row.wait_for(timeout=20_000)
        dry_run_row = text_of(invalid_row)
        assert "7. satır" in dry_run_row
        assert "Malik e-postası" in dry_run_row
        assert "1 satırda hata var" in text_of(by_id(page, "person_import_summary"))

        by_id(page, "person_import_commit_btn").click()
        page.wait_for_function(
            """() => document.querySelector('[flt-semantics-identifier="person_import_summary"]')
              ?.textContent.includes('5 / 6 kayıt eklendi')""",
            timeout=20_000,
        )
        committed_summary = text_of(by_id(page, "person_import_summary"))
        assert "5 / 6 kayıt eklendi" in committed_summary
        assert "1 satır hatalı" in committed_summary
        committed_row = text_of(invalid_row)
        assert "7. satır" in committed_row
        assert "Malik e-postası" in committed_row

        site_id = int(fixture.site_id)
        accepted = stack.sql(
            "SELECT COUNT(*) FROM persons "
            f"WHERE site_id = {site_id} AND email LIKE 'excel.partial.%@example.test';"
        )
        rejected = stack.sql(
            "SELECT COUNT(*) FROM persons "
            f"WHERE site_id = {site_id} AND full_name = 'Excel Invalid Resident';"
        )
        created_units = stack.sql(
            "SELECT COUNT(*) FROM units u JOIN blocks b ON b.id = u.block_id "
            f"WHERE b.site_id = {site_id} AND b.block_name = 'B Blok';"
        )
        assert accepted == "5", accepted
        assert rejected == "0", rejected
        assert created_units == "5", created_units
