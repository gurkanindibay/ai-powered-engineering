/// Field rules for people (person module U2). They mirror the server's checks
/// (`validate_email`, `validate_phone`, `parse_land_share`) so a form can say what
/// is wrong next to the field before anything is sent. Each returns an error
/// message, or `null` when the value is acceptable.
library;

final _email = RegExp(r'^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$');

String? validatePersonEmail(String? value, {bool required = true}) {
  final v = (value ?? '').trim();
  if (v.isEmpty) return required ? 'E-posta adresi gerekli.' : null;
  return _email.hasMatch(v) ? null : 'Geçerli bir e-posta adresi girin (ör. ad@ornek.com).';
}

/// Turkish mobile numbers: 5XX XXX XX XX, with an optional 0 or 90 prefix.
String? validateTrMobile(String? value, {bool required = true}) {
  final digits = (value ?? '').replaceAll(RegExp(r'\D'), '');
  if (digits.isEmpty) return required ? 'Telefon numarası gerekli.' : null;
  final ok = (digits.length == 10 && digits.startsWith('5')) ||
      (digits.length == 11 && digits.startsWith('05')) ||
      (digits.length == 12 && digits.startsWith('905'));
  return ok ? null : 'Geçerli bir cep telefonu girin (ör. 0532 123 45 67).';
}

/// A land share is a positive whole number of shares; empty means "use the site default".
String? validateLandShare(String? value) {
  final v = (value ?? '').trim();
  if (v.isEmpty) return null;
  final n = int.tryParse(v);
  return (n != null && n > 0) ? null : 'Arsa payı pozitif bir tam sayı olmalı.';
}

/// T.C. Kimlik No (person F10): 11 digits, the first not 0, with the two check
/// digits the server also verifies (`is_valid_tckn`).
String? validateTckn(String? value) {
  final v = (value ?? '').replaceAll(RegExp(r'\s'), '');
  if (v.isEmpty) return 'Kimlik numarası gerekli.';
  if (!RegExp(r'^[1-9]\d{10}$').hasMatch(v)) return 'Kimlik numarası 11 haneli olmalı ve 0 ile başlamamalı.';
  final d = v.split('').map(int.parse).toList();
  final odd = d[0] + d[2] + d[4] + d[6] + d[8];
  final even = d[1] + d[3] + d[5] + d[7];
  final tenth = (odd * 7 + 100 - even) % 10;
  final eleventh = d.take(10).fold<int>(0, (a, b) => a + b) % 10;
  return d[9] == tenth && d[10] == eleventh ? null : 'Kimlik numarası geçerli değil.';
}
