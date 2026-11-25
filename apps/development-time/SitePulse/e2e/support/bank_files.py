"""Bank statement and resident import files for upload tests, generated in code so no binary fixtures live in git.

Provides:
- `kuveyt_xlsx`: Kuveyt Türk bank export in OpenXML format
- `statement_csv`: semicolon-separated bank statement CSV (Tarih;Referans;Açıklama;Tutar)
- `statement_mt940`: SWIFT MT940 statement with :61: statement lines and :86: narratives
- `resident_import_xlsx`: resident directory Excel import (.xlsx) compatible with PersonImportXlsx
- `make_viban`: deterministic flat Virtual IBAN generator matching VirtualIbanService
- `build_companion_statement_rows`: dynamically builds the 4 companion statement transactions
- `DEFAULT_RESIDENT_IMPORT_ROWS`: 5 valid rows + 1 invalid format row + 1 duplicate person row
"""
from __future__ import annotations

import io
import zipfile
from dataclasses import dataclass
from decimal import Decimal
from pathlib import Path
from typing import Any
from xml.sax.saxutils import escape

try:
    from .money import format_try
except ImportError:
    try:
        from support.money import format_try
    except ImportError:
        def format_try(amount: Decimal) -> str:
            s = f"{amount:.2f}"
            integer_part, decimal_part = s.split(".")
            negative = integer_part.startswith("-")
            digits = integer_part.lstrip("-")
            grouped = ""
            for i, ch in enumerate(reversed(digits)):
                if i > 0 and i % 3 == 0:
                    grouped = "." + grouped
                grouped = ch + grouped
            if negative:
                grouped = "-" + grouped
            return f"₺{grouped},{decimal_part}"


@dataclass(frozen=True)
class StatementRow:
    date: str            # DD.MM.YYYY
    reference: str
    description: str
    amount: Decimal      # positive = incoming


_CONTENT_TYPES = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
<Default Extension="xml" ContentType="application/xml"/>
<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
<Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
<Override PartName="/xl/sharedStrings.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"/>
</Types>"""

_ROOT_RELS = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
</Relationships>"""

_WORKBOOK = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
<sheets><sheet name="Hesap Hareketleri" sheetId="1" r:id="rId1"/></sheets>
</workbook>"""

_WORKBOOK_RELS = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings" Target="sharedStrings.xml"/>
</Relationships>"""


def _plain_amount(amount: Decimal) -> str:
    """'1.423,33' (Turkish grouping, no currency sign), as the bank exports it."""
    return format_try(amount).replace("₺", "").strip()


def _col_name(idx: int) -> str:
    """Excel column letter from 0-based index: 0->'A', 1->'B', ... 11->'L'."""
    n = idx + 1
    s = ""
    while n > 0:
        s = chr(65 + (n - 1) % 26) + s
        n = (n - 1) // 26
    return s


def make_viban(bank_code: str | int, site_id: str | int, block_name: str, unit_number: int) -> str:
    """Generate deterministic flat virtual IBAN matching VirtualIbanService."""
    bank_code_str = str(bank_code).strip().zfill(5)
    site_id_str = str(site_id)
    site_hash = 9863791
    for b in site_id_str.encode("ascii"):
        site_hash = ((site_hash * 31) + b) & 0xFFFFFFFFFFFFFFFF
    block_hash = sum(block_name.encode("ascii")) & 0xFFFFFFFFFFFFFFFF
    site_prefix = f"{(site_hash + block_hash) % 10_000_000_000:010d}"
    bban = f"{bank_code_str}0{site_prefix}{unit_number:06d}"
    rem = int(f"{bban}292700") % 97
    check = f"{98 - rem:02d}"
    return f"TR{check}{bban}"


def kuveyt_xlsx(path: Path, rows: list[StatementRow], iban: str = "TR620020500009863791600001") -> Path:
    strings: list[str] = []

    def sst(value: str) -> int:
        strings.append(value)
        return len(strings) - 1

    sheet_rows: list[str] = []

    def add_row(number: int, cells: dict[str, str]) -> None:
        xml = "".join(f'<c r="{col}{number}" t="s"><v>{sst(val)}</v></c>' for col, val in cells.items())
        sheet_rows.append(f'<row r="{number}">{xml}</row>')

    add_row(1, {"A": "Kuveyt Türk Katılım Bankası - Hesap Ekstresi"})
    add_row(3, {"A": "IBAN", "B": iban})
    add_row(16, {"B": "Tarih", "C": "Referans", "D": "Açıklama", "E": "Tutar"})
    for i, r in enumerate(rows):
        add_row(17 + i, {"B": r.date, "C": r.reference, "D": r.description, "E": _plain_amount(r.amount)})

    sheet = ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
             '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>'
             + "".join(sheet_rows) + "</sheetData></worksheet>")
    shared = ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
              f'<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="{len(strings)}" '
              f'uniqueCount="{len(strings)}">'
              + "".join(f"<si><t>{escape(v)}</t></si>" for v in strings) + "</sst>")

    path.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("[Content_Types].xml", _CONTENT_TYPES)
        z.writestr("_rels/.rels", _ROOT_RELS)
        z.writestr("xl/workbook.xml", _WORKBOOK)
        z.writestr("xl/_rels/workbook.xml.rels", _WORKBOOK_RELS)
        z.writestr("xl/worksheets/sheet1.xml", sheet)
        z.writestr("xl/sharedStrings.xml", shared)
    return path


def statement_csv(rows: list[StatementRow]) -> str:
    """Build a semicolon-delimited bank statement CSV compatible with BankStatementParser."""
    lines = ["Tarih;Referans;Açıklama;Tutar"]
    for r in rows:
        lines.append(f"{r.date};{r.reference};{r.description};{_plain_amount(r.amount)}")
    content = "\n".join(lines) + "\n"
    return content


def statement_mt940(
    rows: list[StatementRow],
    iban: str = "TR620020500009863791600001",
) -> str:
    """Build a standard SWIFT MT940 statement compatible with Mt940Engine and bank_file_parser.dart."""
    lines = [
        ":20:STARTMR",
        f":25:{iban}",
        ":28C:00001/001",
        ":60F:C261101TRY50000,00",
    ]
    closing_amount = Decimal("50000.00")
    for r in rows:
        parts = r.date.split(".")
        if len(parts) == 3:
            day, month, year = parts
            date_str = f"{year[-2:]}{month.zfill(2)}{day.zfill(2)}"
        else:
            date_str = "261115"
        amount_str = f"{r.amount:.2f}".replace(".", ",")
        closing_amount += r.amount
        lines.append(f":61:{date_str}C{amount_str}NTRFNONREF//{r.reference}")
        lines.append(f":86:{r.description}")
    closing_str = f"{closing_amount:.2f}".replace(".", ",")
    lines.append(f":62F:C261130TRY{closing_str}")
    lines.append("-")
    content = "\n".join(lines) + "\n"
    return content


DEFAULT_RESIDENT_IMPORT_COLUMNS: list[str] = [
    "block",
    "unit_no",
    "floor",
    "owner_full_name",
    "owner_email",
    "owner_phone",
    "land_share",
    "monthly_dues",
    "is_resident",
    "tenant_full_name",
    "tenant_email",
    "tenant_phone",
]

DEFAULT_RESIDENT_IMPORT_ROWS: list[list[str]] = [
    DEFAULT_RESIDENT_IMPORT_COLUMNS,
    # 5 valid resident rows
    ["B Blok", "1", "1", "Kemal Sunal", "kemal.sunal@example.test", "0532 101 00 01", "10", "1.250,00", "evet", "", "", ""],
    ["B Blok", "2", "1", "Şener Şen", "sener.sen@example.test", "0532 101 00 02", "10", "1.250,00", "evet", "", "", ""],
    ["B Blok", "3", "2", "Halit Akçatepe", "halit.akcatepe@example.test", "0532 101 00 03", "12", "1.500,00", "hayır", "Tarık Akan", "tarik.akan@example.test", "0532 201 00 01"],
    ["B Blok", "4", "2", "Adile Naşit", "adile.nasit@example.test", "0532 101 00 04", "10", "1.250,00", "evet", "", "", ""],
    ["B Blok", "5", "3", "Münir Özkul", "munir.ozkul@example.test", "0532 101 00 05", "14", "1.750,00", "evet", "", "", ""],
    # 1 intentionally invalid row (bad format)
    ["B Blok", "XYZ", "abc", "", "invalid-email", "bad-phone", "-5", "not-a-number", "maybe", "", "", ""],
    # 1 duplicate national ID to exercise partial-import error reporting and person merge
    ["B Blok", "6", "3", "Ahmet Yılmaz (10000000146)", "ahmet.duplicate@example.test", "+90 532 111 22 33", "10", "1.250,00", "evet", "", "", ""],
]


def resident_import_xlsx(rows: list[list[str]] | None = None, path: Path | None = None) -> bytes:
    """Builds an OpenXML XLSX workbook (.xlsx) compatible with PersonImportXlsx in flutter."""
    table = rows if rows is not None else DEFAULT_RESIDENT_IMPORT_ROWS
    strings: list[str] = []

    def sst(value: str) -> int:
        strings.append(value)
        return len(strings) - 1

    sheet_rows: list[str] = []
    for row_idx, row_values in enumerate(table, start=1):
        cells_xml = []
        for col_idx, cell_value in enumerate(row_values):
            if not cell_value:
                continue
            col_letter = _col_name(col_idx)
            cells_xml.append(f'<c r="{col_letter}{row_idx}" t="s"><v>{sst(cell_value)}</v></c>')
        if cells_xml:
            sheet_rows.append(f'<row r="{row_idx}">{"".join(cells_xml)}</row>')

    sheet = (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
        f'<cols><col min="1" max="{len(table[0]) if table else 12}" width="20" customWidth="1"/></cols>'
        '<sheetData>' + "".join(sheet_rows) + '</sheetData></worksheet>'
    )
    shared = (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        f'<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="{len(strings)}" '
        f'uniqueCount="{len(strings)}">'
        + "".join(f"<si><t>{escape(v)}</t></si>" for v in strings)
        + "</sst>"
    )

    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("[Content_Types].xml", _CONTENT_TYPES)
        z.writestr("_rels/.rels", _ROOT_RELS)
        z.writestr("xl/workbook.xml", _WORKBOOK.replace("Hesap Hareketleri", "Kisiler"))
        z.writestr("xl/_rels/workbook.xml.rels", _WORKBOOK_RELS)
        z.writestr("xl/worksheets/sheet1.xml", sheet)
        z.writestr("xl/sharedStrings.xml", shared)
    content = buf.getvalue()

    if path is not None:
        p = Path(path)
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(content)
    return content


def build_companion_statement_rows(manifest: dict[str, Any] | None = None) -> list[StatementRow]:
    """Generates the 4 companion statement rows dynamically populated with the active site's Virtual IBANs.

    Transactions:
      1. Clean exact-match payment (real virtual IBAN from active manifest for unit A-1)
      2. Ambiguous multi-debtor Virtual IBAN transfer (unit A-2) landing in UNMATCHED queue (Q11)
      3. Duplicate bank transaction ID (idempotency check matching transaction 1)
      4. Unknown Virtual IBAN
    """
    site_id = str(manifest.get("site_id", "1")) if manifest else "1"
    ref_clock = str(manifest.get("reference_clock", "2026-11-19")) if manifest else "2026-11-19"
    clock_parts = ref_clock.split("-")
    if len(clock_parts) == 3:
        year, month, _ = clock_parts
        date_str = f"15.{month.zfill(2)}.{year}"
    else:
        date_str = "15.11.2026"

    # Virtual IBANs matching backend VirtualIbanService / seeder.py
    viban_clean = make_viban("00205", site_id, "A", 1)
    viban_multi = make_viban("00205", site_id, "A", 2)
    viban_unknown = make_viban("00205", 99999, "Z", 99)

    return [
        StatementRow(
            date=date_str,
            reference="TXN-20261115-001",
            description=f"HAVALE - {viban_clean} A BLOK D:1 AIDAT ODEMESI",
            amount=Decimal("1500.00"),
        ),
        StatementRow(
            date=date_str,
            reference="TXN-20261115-002",
            description=f"HAVALE - {viban_multi} AIDAT",
            amount=Decimal("800.00"),
        ),
        StatementRow(
            date=date_str,
            reference="TXN-20261115-001",
            description=f"HAVALE - {viban_clean} A BLOK D:1 AIDAT ODEMESI TEKRAR",
            amount=Decimal("1500.00"),
        ),
        StatementRow(
            date=date_str,
            reference="TXN-20261115-004",
            description=f"HAVALE - {viban_unknown} BILINMEYEN HESAP",
            amount=Decimal("500.00"),
        ),
    ]
