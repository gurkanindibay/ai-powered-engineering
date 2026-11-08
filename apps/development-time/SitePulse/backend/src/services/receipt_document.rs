//! Receipt PDF with a verification QR code, SPEC-007 R3.
//!
//! The PDF is rendered from the stored receipt (the issued document's snapshot);
//! nothing is recomputed. The QR code points to the public verification endpoint,
//! which confirms the receipt number, date, amount and issuer without disclosing
//! the payer (KVKK).

use chrono::{DateTime, Utc};
use printpdf::{
    Color, IndirectFontRef, Line, Mm, PdfDocument, PdfLayerReference, Point, Rect, Rgb,
};
use rust_decimal::{Decimal, RoundingStrategy};

use crate::models::{PaymentReceipt, LEDGER_KIND_REVERSAL};

const FONT_REGULAR: &[u8] = include_bytes!("../../assets/fonts/DejaVuSans.ttf");
const FONT_BOLD: &[u8] = include_bytes!("../../assets/fonts/DejaVuSans-Bold.ttf");

/// `1234.5` -> `1.234,50` (Turkish grouping, always two decimals).
pub fn format_try(amount: Decimal) -> String {
    let rounded = amount.round_dp_with_strategy(2, RoundingStrategy::MidpointAwayFromZero);
    let negative = rounded.is_sign_negative() && !rounded.is_zero();
    let text = format!("{:.2}", rounded.abs());
    let (int_part, frac) = text.split_once('.').unwrap_or((&text, "00"));
    let mut grouped = String::new();
    for (i, ch) in int_part.chars().enumerate() {
        if i > 0 && (int_part.len() - i) % 3 == 0 {
            grouped.push('.');
        }
        grouped.push(ch);
    }
    format!("{}{},{}", if negative { "-" } else { "" }, grouped, frac)
}

/// The public URL that verifies a receipt (encoded in the QR code).
pub fn verification_url(receipt: &PaymentReceipt) -> String {
    format!(
        "{}/api/v1/public/receipts/verify?no={}&h={}",
        crate::services::card_payment_service::public_base_url(),
        receipt.receipt_number,
        receipt.verification_hash
    )
}

fn role_tr(role: &str) -> &'static str {
    match role {
        "TENANT" => "Kiracı",
        _ => "Kat Maliki",
    }
}

fn channel_tr(channel: &str) -> &str {
    match channel {
        "VIRTUAL_IBAN" => "Sanal IBAN havale/EFT",
        "BANK_STATEMENT" => "Banka ekstresi",
        "BANK_TRANSFER" => "Havale/EFT",
        "CREDIT_CARD" => "Kredi kartı",
        "MANUAL_CASH" | "CASH" => "Nakit",
        "INTER_LEDGER" => "Avanstan virman",
        "ONLINE_PAYMENT" => "Çevrimiçi ödeme",
        other => other,
    }
}

fn expense_tr(expense: &str) -> &str {
    match expense {
        "OPERATIONAL_DUES" => "Aidat (işletme)",
        "CAPITAL_DUES" => "Demirbaş / yatırım",
        other => other,
    }
}

fn istanbul(ts: DateTime<Utc>) -> String {
    ts.with_timezone(&chrono_tz::Europe::Istanbul)
        .format("%d.%m.%Y %H:%M")
        .to_string()
}

/// Greedy word wrap to at most `width` characters per line.
fn wrap(text: &str, width: usize) -> Vec<String> {
    let mut lines = Vec::new();
    for paragraph in text.split('\n') {
        let mut line = String::new();
        for word in paragraph.split_whitespace() {
            if !line.is_empty() && line.chars().count() + 1 + word.chars().count() > width {
                lines.push(std::mem::take(&mut line));
            }
            if !line.is_empty() {
                line.push(' ');
            }
            line.push_str(word);
        }
        lines.push(line);
    }
    lines
}

struct Pen<'a> {
    layer: PdfLayerReference,
    regular: &'a IndirectFontRef,
    bold: &'a IndirectFontRef,
    y: f32,
}

impl Pen<'_> {
    fn text(&self, s: &str, size: f32, x: f32, bold: bool) {
        self.layer.use_text(
            s,
            size,
            Mm(x),
            Mm(self.y),
            if bold { self.bold } else { self.regular },
        );
    }
    fn row(&mut self, label: &str, value: &str) {
        self.text(label, 9.0, 18.0, false);
        self.text(value, 9.0, 70.0, true);
        self.y -= 5.5;
    }
    fn rule(&mut self) {
        self.layer.add_line(Line {
            points: vec![
                (Point::new(Mm(18.0), Mm(self.y)), false),
                (Point::new(Mm(192.0), Mm(self.y)), false),
            ],
            is_closed: false,
        });
        self.y -= 6.0;
    }
}

/// Renders one receipt as an A4 PDF. `unit_label` is the unit's display label.
pub fn render_receipt_pdf(receipt: &PaymentReceipt, unit_label: &str) -> Result<Vec<u8>, String> {
    let reversal = receipt.receipt_type == LEDGER_KIND_REVERSAL;
    let title = if reversal {
        "İPTAL / İADE MAKBUZU"
    } else {
        "TAHSİLAT MAKBUZU"
    };
    let (doc, page, layer) = PdfDocument::new(
        format!("{} {}", title, receipt.receipt_number),
        Mm(210.0),
        Mm(297.0),
        "receipt",
    );
    let regular = doc
        .add_external_font(std::io::Cursor::new(FONT_REGULAR))
        .map_err(|e| e.to_string())?;
    let bold = doc
        .add_external_font(std::io::Cursor::new(FONT_BOLD))
        .map_err(|e| e.to_string())?;
    let mut pen = Pen {
        layer: doc.get_page(page).get_layer(layer),
        regular: &regular,
        bold: &bold,
        y: 277.0,
    };

    // Issuer
    pen.text(
        receipt.issuer_name.as_deref().unwrap_or("Site Yönetimi"),
        13.0,
        18.0,
        true,
    );
    pen.y -= 6.0;
    if let Some(ref address) = receipt.issuer_address {
        for l in wrap(address, 90) {
            pen.text(&l, 8.5, 18.0, false);
            pen.y -= 4.5;
        }
    }
    let tax = match (&receipt.issuer_tax_id, &receipt.issuer_tax_office) {
        (Some(id), Some(office)) => Some(format!("VKN/TCKN {} · {} V.D.", id, office)),
        (Some(id), None) => Some(format!("VKN/TCKN {}", id)),
        _ => None,
    };
    if let Some(t) = tax {
        pen.text(&t, 8.5, 18.0, false);
        pen.y -= 4.5;
    }
    pen.y -= 4.0;
    pen.text(title, 16.0, 18.0, true);
    pen.y -= 9.0;
    pen.rule();

    pen.row("Makbuz No", &receipt.receipt_number);
    pen.row("Düzenlenme", &istanbul(receipt.issued_at));
    pen.row("Bağımsız bölüm", unit_label);
    pen.row(
        "Ödeyen",
        &format!(
            "{} ({})",
            receipt.payer_name,
            role_tr(receipt.payer_role.as_str())
        ),
    );
    if let Some(ref on_behalf) = receipt.on_behalf_of_name {
        pen.row(
            "Adına ödenen",
            &format!(
                "{} ({})",
                on_behalf,
                role_tr(
                    receipt
                        .on_behalf_of_role
                        .map(|r| r.as_str())
                        .unwrap_or("OWNER")
                )
            ),
        );
    }
    pen.row("Ödeme kanalı", channel_tr(receipt.payment_channel.as_str()));
    if let Some(ref reference) = receipt.channel_reference {
        pen.row(
            if reversal {
                "İptal edilen makbuz"
            } else {
                "Kanal referansı"
            },
            reference,
        );
    }
    pen.y -= 2.0;
    pen.text("Tutar", 10.0, 18.0, false);
    pen.text(
        &format!("₺{}", format_try(receipt.total_amount)),
        16.0,
        70.0,
        true,
    );
    pen.y -= 9.0;
    pen.rule();

    // Allocation
    pen.text("Mahsup edilen borçlar", 10.0, 18.0, true);
    pen.y -= 6.0;
    pen.text("Dönem", 8.5, 18.0, true);
    pen.text("Borç türü", 8.5, 75.0, true);
    pen.text("Anapara", 8.5, 128.0, true);
    pen.text("Gecikme tazminatı", 8.5, 155.0, true);
    pen.y -= 5.0;
    if receipt.allocation_breakdown.is_empty() {
        pen.text("—", 9.0, 18.0, false);
        pen.y -= 5.0;
    }
    for item in &receipt.allocation_breakdown {
        if pen.y < 70.0 {
            break;
        }
        pen.text(&item.period, 9.0, 18.0, false);
        pen.text(expense_tr(item.expense_type.as_str()), 9.0, 75.0, false);
        pen.text(&format_try(item.principal_paid), 9.0, 128.0, false);
        pen.text(&format_try(item.penalty_paid), 9.0, 155.0, false);
        pen.y -= 5.0;
    }
    pen.y -= 2.0;
    pen.row(
        "Toplam anapara",
        &format!("₺{}", format_try(receipt.allocated_principal)),
    );
    pen.row(
        "Toplam gecikme tazminatı",
        &format!("₺{}", format_try(receipt.allocated_penalty)),
    );
    if receipt.allocated_advance > Decimal::ZERO {
        let whose = receipt
            .advance_debtor_type
            .as_deref()
            .map(role_tr)
            .unwrap_or("Ödeyen");
        pen.row(
            "Avans (fazla ödeme)",
            &format!(
                "₺{} · {} avansı",
                format_try(receipt.allocated_advance),
                whose
            ),
        );
    }
    pen.rule();

    if let Some(ref note) = receipt.legal_statutory_note {
        for l in wrap(note, 105).into_iter().take(10) {
            pen.text(&l, 8.0, 18.0, false);
            pen.y -= 4.2;
        }
        pen.y -= 3.0;
    }

    // Verification
    let url = verification_url(receipt);
    let qr = qrcode::QrCode::new(url.as_bytes()).map_err(|e| e.to_string())?;
    let modules = qr.width();
    let size_mm = 32.0_f32;
    let cell = size_mm / modules as f32;
    let (left, top) = (18.0_f32, 52.0_f32);
    pen.layer
        .set_fill_color(Color::Rgb(Rgb::new(0.0, 0.0, 0.0, None)));
    for (i, color) in qr.to_colors().iter().enumerate() {
        if *color == qrcode::Color::Dark {
            let (x, y) = ((i % modules) as f32, (i / modules) as f32);
            let x0 = left + x * cell;
            let y0 = top - (y + 1.0) * cell;
            pen.layer
                .add_rect(Rect::new(Mm(x0), Mm(y0), Mm(x0 + cell), Mm(y0 + cell)));
        }
    }
    pen.y = 48.0;
    pen.text("Doğrulama", 9.0, 56.0, true);
    pen.y -= 5.0;
    pen.text(
        "Makbuzu doğrulamak için QR kodu okutun veya adresi açın:",
        8.0,
        56.0,
        false,
    );
    pen.y -= 4.5;
    // A URL has no spaces to wrap at: cut it into fixed-width pieces.
    let url_chars: Vec<char> = url.chars().collect();
    for l in url_chars.chunks(78).map(|c| c.iter().collect::<String>()) {
        pen.text(&l, 7.0, 56.0, false);
        pen.y -= 4.0;
    }
    pen.y -= 1.0;
    pen.text(
        &format!("Doğrulama kodu: {}", receipt.verification_hash),
        7.0,
        56.0,
        false,
    );
    pen.y = 12.0;
    pen.text(
        "Bu makbuz SitePulse tarafından elektronik olarak düzenlenmiştir.",
        7.5,
        18.0,
        false,
    );

    doc.save_to_bytes().map_err(|e| e.to_string())
}

// ---------------------------------------------------------------------------
// SPEC-009: generic text documents (ihtarname draft, rent-deduction
// certificate, account report, evidence pack). Coordinates are layout values,
// not money; every amount arrives already formatted.
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
#[error("The document could not be rendered: {0}")]
pub struct DocumentError(pub String);

/// A table: header cells and rows of the same width.
#[derive(Debug, Clone, Default)]
pub struct DocTable {
    pub headers: Vec<String>,
    pub rows: Vec<Vec<String>>,
}

#[derive(Debug, Clone, Default)]
pub struct DocSection {
    pub heading: Option<String>,
    /// Label / value pairs.
    pub rows: Vec<(String, String)>,
    pub paragraphs: Vec<String>,
    pub table: Option<DocTable>,
}

#[derive(Debug, Clone, Default)]
pub struct TextDocument {
    pub issuer: String,
    pub issuer_lines: Vec<String>,
    pub title: String,
    pub sections: Vec<DocSection>,
    pub footer: String,
}

/// `format_try` with the lira sign, for document rows.
pub fn try_amount(amount: Decimal) -> String {
    format!("₺{}", format_try(amount))
}

/// Renders a multi-page A4 document with the embedded DejaVu fonts.
pub fn render_text_document(document: &TextDocument) -> Result<Vec<u8>, DocumentError> {
    let err = |e: &dyn std::fmt::Display| DocumentError(e.to_string());
    let (doc, page, layer) =
        PdfDocument::new(document.title.clone(), Mm(210.0), Mm(297.0), "page-1");
    let regular = doc
        .add_external_font(std::io::Cursor::new(FONT_REGULAR))
        .map_err(|e| err(&e))?;
    let bold = doc
        .add_external_font(std::io::Cursor::new(FONT_BOLD))
        .map_err(|e| err(&e))?;
    let mut pen = Pen {
        layer: doc.get_page(page).get_layer(layer),
        regular: &regular,
        bold: &bold,
        y: 277.0,
    };
    let mut pages = 1;
    let mut ensure = |pen: &mut Pen, needed: f32| {
        if pen.y - needed < 18.0 {
            pages += 1;
            let (p, l) = doc.add_page(Mm(210.0), Mm(297.0), format!("page-{}", pages));
            pen.layer = doc.get_page(p).get_layer(l);
            pen.y = 277.0;
        }
    };
    pen.text(&document.issuer, 13.0, 18.0, true);
    pen.y -= 6.0;
    for l in &document.issuer_lines {
        for w in wrap(l, 95) {
            pen.text(&w, 8.5, 18.0, false);
            pen.y -= 4.5;
        }
    }
    pen.y -= 4.0;
    for w in wrap(&document.title, 60) {
        pen.text(&w, 15.0, 18.0, true);
        pen.y -= 8.0;
    }
    pen.rule();
    for section in &document.sections {
        if let Some(ref h) = section.heading {
            ensure(&mut pen, 14.0);
            pen.text(h, 10.5, 18.0, true);
            pen.y -= 6.5;
        }
        for (label, value) in &section.rows {
            ensure(&mut pen, 6.0);
            pen.row(label, value);
        }
        for p in &section.paragraphs {
            for w in wrap(p, 105) {
                ensure(&mut pen, 5.0);
                pen.text(&w, 8.5, 18.0, false);
                pen.y -= 4.4;
            }
            pen.y -= 2.0;
        }
        if let Some(ref table) = section.table {
            let columns = table.headers.len().max(1);
            let width = 174.0 / columns as f32;
            let chars = ((width / 1.8) as usize).max(4);
            let cell = |s: &str| s.chars().take(chars).collect::<String>();
            ensure(&mut pen, 10.0);
            for (i, h) in table.headers.iter().enumerate() {
                pen.text(&cell(h), 8.0, 18.0 + width * i as f32, true);
            }
            pen.y -= 5.0;
            for row in &table.rows {
                ensure(&mut pen, 5.0);
                for (i, c) in row.iter().enumerate().take(columns) {
                    pen.text(&cell(c), 8.0, 18.0 + width * i as f32, false);
                }
                pen.y -= 4.6;
            }
            pen.y -= 2.0;
        }
        pen.y -= 2.0;
        ensure(&mut pen, 8.0);
        pen.rule();
    }
    ensure(&mut pen, 10.0);
    for w in wrap(&document.footer, 110) {
        pen.text(&w, 7.5, 18.0, false);
        pen.y -= 4.0;
    }
    doc.save_to_bytes().map_err(|e| err(&e))
}
