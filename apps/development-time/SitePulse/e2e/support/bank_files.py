"""Bank statement files for upload tests, generated in code so no binary fixtures live in git.

`kuveyt_xlsx` writes a minimal but valid OpenXML workbook in the Kuveyt Türk export layout the
client parser reads (`flutter/lib/domain/services/bank_file_parser.dart`): account header rows
1-16, transactions from row 17, column B date (DD.MM.YYYY), C reference, D description,
E amount as Turkish-formatted text ("1.423,33"). Every cell is a shared string, as in the real export.
"""
from __future__ import annotations

import zipfile
from dataclasses import dataclass
from decimal import Decimal
from pathlib import Path
from xml.sax.saxutils import escape

from .money import format_try


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
