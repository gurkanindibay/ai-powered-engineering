/// Field rules for people (person module U2). They mirror the server's checks
/// (`validate_email`, `validate_phone`, `parse_land_share`) so a form can say what
/// is wrong next to the field before anything is sent. Each returns an error
/// message, or `null` when the value is acceptable.
library;

final _email = RegExp(r'^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$');

String? validatePersonEmail(String? value, {bool required = true}) {
  final v = (value ?? '').trim();
  if (v.isEmpty) return required ? 'E-posta adresi gerekli.' : null;
  return _email.hasMatch(v)
      ? null
      : 'Geçerli bir e-posta adresi girin (ör. ad@ornek.com).';
}

/// Turkish mobile numbers: 5XX XXX XX XX, with an optional 0 or 90 prefix.
String? validateTrMobile(String? value, {bool required = true}) {
  final digits = (value ?? '').replaceAll(RegExp(r'\D'), '');
  if (digits.isEmpty) return required ? 'Telefon numarası gerekli.' : null;
  final ok =
      (digits.length == 10 && digits.startsWith('5')) ||
      (digits.length == 11 && digits.startsWith('05')) ||
      (digits.length == 12 && digits.startsWith('905'));
  return ok ? null : 'Geçerli bir cep telefonu girin (ör. 0532 123 45 67).';
}

/// Turkish IBANs contain 26 characters and must pass the ISO 13616 mod-97 check.
String? validateTrIban(String? value, {bool required = true}) {
  final iban = (value ?? '').replaceAll(RegExp(r'\s+'), '').toUpperCase();
  if (iban.isEmpty) return required ? 'IBAN gerekli.' : null;
  if (!RegExp(r'^TR\d{24}$').hasMatch(iban)) {
    return 'Geçerli bir Türkiye IBAN’ı girin (TR ile başlayan 26 karakter).';
  }

  final rearranged = '${iban.substring(4)}${iban.substring(0, 4)}';
  var remainder = 0;
  for (final character in rearranged.split('')) {
    final code = character.codeUnitAt(0);
    final digits = code >= 65 && code <= 90
        ? (code - 55).toString()
        : character;
    for (final digit in digits.split('')) {
      remainder = (remainder * 10 + int.parse(digit)) % 97;
    }
  }
  return remainder == 1 ? null : 'IBAN kontrol basamağı geçerli değil.';
}

/// A land share is a positive whole number of shares; empty means "use the site default".
String? validateLandShare(String? value) {
  final v = (value ?? '').trim();
  if (v.isEmpty) return null;
  final parts = v.split('/');
  final n = int.tryParse(parts.first.trim());
  const maxShare = 2147483647;
  final validDenominator =
      parts.length == 1 ||
      (parts.length == 2 &&
          (int.tryParse(parts[1].trim()) ?? 0) > 0 &&
          int.parse(parts[1].trim()) <= maxShare);
  return (n != null && n > 0 && n <= maxShare && validDenominator)
      ? null
      : 'Arsa payı pozitif bir tam sayı olmalı.';
}

/// Reads the numerator accepted by the server for legacy `n/d` land-share input.
int? parseLandShare(String? value) {
  final v = (value ?? '').trim();
  if (v.isEmpty) return null;
  if (validateLandShare(v) != null) return null;
  final n = int.tryParse(v.split('/').first.trim());
  return n != null && n > 0 ? n : null;
}

/// T.C. Kimlik No (person F10): 11 digits, the first not 0, with the two check
/// digits the server also verifies (`is_valid_tckn`).
String? validateTckn(String? value) {
  final v = (value ?? '').replaceAll(RegExp(r'\s'), '');
  if (v.isEmpty) return 'Kimlik numarası gerekli.';
  if (!RegExp(r'^[1-9]\d{10}$').hasMatch(v))
    return 'Kimlik numarası 11 haneli olmalı ve 0 ile başlamamalı.';
  final d = v.split('').map(int.parse).toList();
  final odd = d[0] + d[2] + d[4] + d[6] + d[8];
  final even = d[1] + d[3] + d[5] + d[7];
  final tenth = (odd * 7 + 100 - even) % 10;
  final eleventh = d.take(10).fold<int>(0, (a, b) => a + b) % 10;
  return d[9] == tenth && d[10] == eleventh
      ? null
      : 'Kimlik numarası geçerli değil.';
}
