import 'package:decimal/decimal.dart';

/// The only way the UI turns an amount into text.
///
/// Formats a [Decimal] in the Turkish Lira style used across the app,
/// `₺1.423,33`: dot thousands separators, comma decimal separator, always two
/// kuruş digits. It works on the decimal string directly and never goes
/// through `double`, so large amounts and half-kuruş values do not drift.
class MoneyFormatter {
  const MoneyFormatter._();

  static const String symbol = '₺';

  /// `₺1.423,33`, or `-₺1.423,33` for negative amounts.
  static String format(Decimal amount) {
    final rounded = amount.round(scale: 2);
    final negative = rounded < Decimal.zero;
    final digits = (negative ? -rounded : rounded).toStringAsFixed(2);
    final dot = digits.indexOf('.');
    final integerPart = digits.substring(0, dot);
    final fraction = digits.substring(dot + 1);
    return '${negative ? '-' : ''}$symbol${_group(integerPart)},$fraction';
  }

  /// Signed form for ledgers: `+₺500,00` for credits, `-₺500,00` for debits.
  static String formatSigned(Decimal amount) {
    if (amount > Decimal.zero) return '+${format(amount)}';
    return format(amount);
  }

  /// A credit shown with an explicit plus sign, whatever the stored sign.
  static String formatCredit(Decimal amount) => '+${format(amount.abs())}';

  /// Plain number without the currency symbol, for text fields: `1423,33`.
  static String formatPlain(Decimal amount) =>
      format(amount).replaceFirst(symbol, '');

  /// Parses user input such as `1.423,33`, `1423,33`, `1423.33` or `₺1.423`.
  /// Returns null when the text is not an amount.
  static Decimal? tryParse(String input) {
    var text = input.replaceAll(symbol, '').replaceAll(' ', '').replaceAll(' ', '').trim();
    if (text.isEmpty) return null;
    final hasComma = text.contains(',');
    if (hasComma) {
      // Turkish style: dots group thousands, the comma separates kuruş.
      text = text.replaceAll('.', '').replaceAll(',', '.');
    } else if (RegExp(r'^\d{1,3}(\.\d{3})+$').hasMatch(text)) {
      // `1.423` or `1.234.567` with no comma: dots are thousands separators.
      text = text.replaceAll('.', '');
    }
    if (!RegExp(r'^-?\d+(\.\d+)?$').hasMatch(text)) return null;
    return Decimal.tryParse(text);
  }

  static String _group(String digits) {
    final buffer = StringBuffer();
    for (var i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) buffer.write('.');
      buffer.write(digits[i]);
    }
    return buffer.toString();
  }
}

/// Shorthand for [MoneyFormatter.format].
String formatTry(Decimal amount) => MoneyFormatter.format(amount);
