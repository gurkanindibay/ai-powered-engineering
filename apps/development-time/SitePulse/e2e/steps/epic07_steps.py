"""Steps for EPIC-07, .specify/features/EPIC-07."""
from __future__ import annotations

from pathlib import Path
from zipfile import ZipFile

import pytest
from pytest_bdd import given, parsers, then, when

from pages import DuesManagement, ImportSummary, ManagerCockpit
from support.flutter import by_id, by_id_prefix

EXCEL_BANKS = {
    "KUVEYT_TURK": "Kuveyt Türk Katılım Bankası",
    "YAPI_KREDI": "Yapı Kredi Bankası",
}


@pytest.fixture
def bank_code(_pytest_bdd_example: dict[str, str]) -> str:
    return _pytest_bdd_example.get("bank_code", "")


@pytest.fixture
def bank_name(_pytest_bdd_example: dict[str, str]) -> str:
    return _pytest_bdd_example.get("bank_name", "")


@given(parsers.parse('the supported-bank catalogue contains bank "{bank_code}" with format "{statement_format}"'))
def supported_bank_catalogue(bank_code: str, statement_format: str) -> None:
    assert statement_format == "EXCEL"
    assert bank_code in EXCEL_BANKS, f"Bank {bank_code} not catalogued with format EXCEL"


@given("the manager opens Excel / statement upload")
def open_statement_upload(login_as, page) -> None:
    login_as("manager")
    ManagerCockpit(page).wait()
    DuesManagement(page).open()
    by_id(page, "btn_open_bank_import").click()


@when("the sample workbook options are displayed")
def sample_options_displayed(page) -> None:
    by_id_prefix(page, "btn_download_bank_sample_").first.wait_for(timeout=10_000)


@then(parsers.parse('a downloadable sample workbook is shown for "{bank_name}"'))
def downloadable_sample_shown(page, bank_code: str, bank_name: str) -> None:
    code = bank_code.lower()
    btn = by_id(page, f"btn_download_bank_sample_{code}")
    btn.wait_for(timeout=10_000)
    assert btn.count() == 1


@then("the downloaded workbook is a valid Excel file with fictional transaction rows", target_fixture="downloaded_sample")
def download_sample_workbook(page, tmp_path: Path, bank_code: str, bank_name: str) -> Path:
    code = bank_code.lower()
    with page.expect_download() as download_info:
        by_id(page, f"btn_download_bank_sample_{code}").click()
    download = download_info.value
    assert download.suggested_filename == f"{code}_ornek_ekstre.xlsx"
    saved_path = tmp_path / download.suggested_filename
    download.save_as(saved_path)
    with ZipFile(saved_path) as workbook:
        shared_strings = workbook.read("xl/sharedStrings.xml").decode("utf-8")
        worksheet = workbook.read("xl/worksheets/sheet1.xml").decode("utf-8")
    assert bank_name in shared_strings
    assert f"SAMPLE-{bank_code}-001" in shared_strings
    assert "Z BLOK D:999" in shared_strings
    assert "0,01" in shared_strings
    assert 'r="E17"' in worksheet
    return saved_path


@then("uploading the sample does not settle or mutate real dues")
def upload_sample_does_not_mutate(page, stack, downloaded_sample: Path) -> None:
    payments_before = stack.sql("SELECT count(*) FROM payment_entries;")
    paid_before = stack.sql("SELECT coalesce(sum(paid_amount), 0) FROM dues_liabilities;")
    with page.expect_file_chooser() as chooser:
        by_id(page, "btn_import_pick_file").click()
    chooser.value.set_files(str(downloaded_sample))
    summary = ImportSummary(page).wait()
    assert summary.matched()[0] == 0
    assert stack.sql("SELECT count(*) FROM payment_entries;") == payments_before
    assert stack.sql("SELECT coalesce(sum(paid_amount), 0) FROM dues_liabilities;") == paid_before
