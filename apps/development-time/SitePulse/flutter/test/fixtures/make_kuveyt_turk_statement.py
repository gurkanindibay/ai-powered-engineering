#!/usr/bin/env python3
"""Writes the synthetic Kuveyt Turk account statement used by test/bank_file_parser_test.dart.

The file mimics the layout of a Kuveyt Turk "hesap-ekstresi.xlsx" export as far as
BankFileParser.parseXlsxBytes reads it: account header rows above row 17, then one
transaction per row with the date as an Excel serial in column B, the reference in C,
the description (a shared string) in D and the signed amount in E.

Every name, reference and amount is made up. Payers are the residents of
test/test_fixtures.dart, so the reconciliation matcher has something to match; no real
statement or customer data is used.

Usage:
    python3 test/fixtures/make_kuveyt_turk_statement.py            # (re)write the fixture
    python3 test/fixtures/make_kuveyt_turk_statement.py --check    # exit 1 if the file is stale
"""
from __future__ import annotations

import argparse
import io
import sys
import zipfile
from datetime import date
from pathlib import Path
from xml.sax.saxutils import escape

OUT = Path(__file__).resolve().parent / "kuveyt_turk_statement_synthetic.xlsx"
RECIPIENT = "BEGONYA SİTESİ YÖNETİMİ"
EXCEL_EPOCH = date(1899, 12, 30)
FIXED_ZIP_TIME = (2026, 10, 1, 0, 0, 0)  # deterministic bytes for --check

# (day in October 2026, reference, description, amount as written in the statement)
TRANSACTIONS = [
    (1, "SYN0001", f"Para Transferi, Gönderen: ALAETTİN ÇELİK  , Alıcı: {RECIPIENT}, Ekim aidatı", "1320.00"),
    (1, "SYN0002", f"aidat B blok - Gönderen:MUSTAFA RÜZGAR, Alıcı:{RECIPIENT}, FAST", "715.00"),
    (2, "SYN0003", f"sait - Gönderen:SAİT ŞENER, Alıcı:{RECIPIENT}, FAST", "715.00"),
    (2, "SYN0004", f"Para Transferi, Gönderen: SERVET KARACA, Alıcı: {RECIPIENT}, Ekim aidatı", "715.00"),
    (3, "SYN0005", f"Para Transferi, Gönderen: AHMET YILMAZ, Alıcı: {RECIPIENT}, Ekim aidatı", "1423.33"),
    (3, "SYN0006", f"Para Transferi, Gönderen: FATMA KAYA, Alıcı: {RECIPIENT}, aidat", "1411.67"),
    (4, "SYN0007", f"Para Transferi, Gönderen: MEHMET ÖZ, Alıcı: {RECIPIENT}, aidat", "1404.67"),
    (4, "SYN0008", f"Para Transferi, Gönderen: MUSTAFA BURAK TÜRKMEN, Alıcı: {RECIPIENT}", "1000.00"),
    (5, "SYN0009", f"Para Transferi, Gönderen: ÖRNEK KİRACI BİR, Alıcı: {RECIPIENT}, kira payı", "650.00"),
    (5, "SYN0010", f"Para Transferi, Gönderen: ÖRNEK KİRACI İKİ, Alıcı: {RECIPIENT}", "480.50"),
    (6, "SYN0011", f"Para Transferi, Gönderen: DENEME GÖNDEREN, Alıcı: {RECIPIENT}, bağış", "250.00"),
    (6, "SYN0012", f"Para Transferi, Gönderen: SELİM AK, Alıcı: {RECIPIENT}, avans", "200.00"),
    (7, "SYN0013", f"Para Transferi, Gönderen: CANAN ECE, Alıcı: {RECIPIENT}, avans", "300.00"),
    (7, "SYN0014", f"Para Transferi, Gönderen: ALİ DEMİR, Alıcı: {RECIPIENT}, avans", "150.00"),
    (8, "SYN0015", "Kâr payı tahakkuku", "12.34"),
    (8, "SYN0016", f"Para Transferi, Gönderen: ÖRNEK KİRACI ÜÇ, Alıcı: {RECIPIENT}", "715.00"),
    (9, "SYN0017", "Giden Havale, Alıcı: ÖRNEK TADİLAT LTD ŞTİ, çatı onarımı", "-14000.00"),
    (9, "SYN0018", "Giden EFT, Alıcı: ÖRNEK ASANSÖR BAKIM, Ekim bakımı", "-1250.00"),
]

HEADER_ROWS = [
    (2, "KUVEYT TÜRK KATILIM BANKASI A.Ş. - HESAP EKSTRESİ (SENTETİK TEST VERİSİ)"),
    (4, f"Hesap Sahibi: {RECIPIENT}"),
    (5, "IBAN: TR00 0000 0000 0000 0000 0000 00"),
    (6, "Dönem: 01.10.2026 - 09.10.2026"),
]


def build() -> bytes:
    strings: list[str] = []

    def shared(text: str) -> int:
        if text not in strings:
            strings.append(text)
        return strings.index(text)

    rows: list[str] = []
    for number, text in HEADER_ROWS:
        rows.append(f'<row r="{number}"><c r="B{number}" t="s"><v>{shared(text)}</v></c></row>')
    rows.append('<row r="16">' + "".join(
        f'<c r="{col}16" t="s"><v>{shared(label)}</v></c>'
        for col, label in zip("BCDE", ["Tarih", "Referans", "Açıklama", "Tutar"])) + "</row>")
    rows.append(f'<row r="17"><c r="B17"><v>{(date(2026, 10, 1) - EXCEL_EPOCH).days}</v></c>'
                f'<c r="C17" t="s"><v>{shared("SYN0000")}</v></c>'
                f'<c r="D17" t="s"><v>{shared("Devir Bakiyesi")}</v></c><c r="E17"><v>50000.00</v></c></row>')
    for offset, (day, ref, desc, amount) in enumerate(TRANSACTIONS):
        number = 18 + offset
        serial = (date(2026, 10, day) - EXCEL_EPOCH).days
        rows.append(f'<row r="{number}"><c r="B{number}"><v>{serial}</v></c>'
                    f'<c r="C{number}" t="s"><v>{shared(ref)}</v></c>'
                    f'<c r="D{number}" t="s"><v>{shared(desc)}</v></c>'
                    f'<c r="E{number}"><v>{amount}</v></c></row>')

    main_ns = 'xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"'
    rel_ns = 'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"'
    files = {
        "[Content_Types].xml": (
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
            '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
            '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
            '<Default Extension="xml" ContentType="application/xml"/>'
            '<Override PartName="/xl/workbook.xml" '
            'ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
            '<Override PartName="/xl/worksheets/sheet1.xml" '
            'ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>'
            '<Override PartName="/xl/sharedStrings.xml" '
            'ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"/>'
            '</Types>'),
        "_rels/.rels": (
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
            '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
            '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/'
            'officeDocument" Target="xl/workbook.xml"/></Relationships>'),
        "xl/workbook.xml": (
            f'<?xml version="1.0" encoding="UTF-8" standalone="yes"?><workbook {main_ns} {rel_ns}>'
            '<sheets><sheet name="Hesap Hareketleri" sheetId="1" r:id="rId1"/></sheets></workbook>'),
        "xl/_rels/workbook.xml.rels": (
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
            '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
            '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/'
            'worksheet" Target="worksheets/sheet1.xml"/>'
            '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/'
            'sharedStrings" Target="sharedStrings.xml"/></Relationships>'),
        "xl/worksheets/sheet1.xml": (
            f'<?xml version="1.0" encoding="UTF-8" standalone="yes"?><worksheet {main_ns}>'
            f'<sheetData>{"".join(rows)}</sheetData></worksheet>'),
    }
    files["xl/sharedStrings.xml"] = (
        f'<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        f'<sst {main_ns} count="{len(strings)}" uniqueCount="{len(strings)}">'
        + "".join(f"<si><t>{escape(s)}</t></si>" for s in strings) + "</sst>")

    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w", zipfile.ZIP_DEFLATED) as archive:
        for name, content in files.items():
            info = zipfile.ZipInfo(name, date_time=FIXED_ZIP_TIME)
            info.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(info, content.encode("utf-8"))
    return buffer.getvalue()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--check", action="store_true", help="exit 1 when the committed fixture differs")
    args = parser.parse_args(argv)
    data = build()
    if args.check:
        current = OUT.read_bytes() if OUT.exists() else b""
        if current != data:
            print(f"{OUT.name} is stale; run {Path(__file__).name} to regenerate it")
            return 1
        print(f"{OUT.name} is up to date")
        return 0
    OUT.write_bytes(data)
    print(f"wrote {OUT} ({len(data)} bytes, {len(TRANSACTIONS)} transactions)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
