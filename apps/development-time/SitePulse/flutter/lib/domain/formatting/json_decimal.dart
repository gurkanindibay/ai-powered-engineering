import 'dart:developer' as developer;

import 'package:decimal/decimal.dart';

/// Called when an API payload carries a value that is present but is not a
/// decimal. Replaceable in tests; defaults to a `dart:developer` log entry so
/// malformed money is visible instead of silently becoming zero.
void Function(String key, Object value) onMalformedDecimal = _logMalformedDecimal;

void _logMalformedDecimal(String key, Object value) {
  developer.log('Malformed decimal for "$key": $value', name: 'sitepulse.json_decimal', level: 900);
}

/// Parses `json[key]` as a [Decimal].
///
/// * a missing key or `null` value returns [fallback];
/// * a numeric or string value is parsed through its string form (never via
///   `double` arithmetic);
/// * a present but unparsable value is reported via [onMalformedDecimal] and
///   returns [fallback].
///
/// [fallback] defaults to zero, which matches how the API encodes empty
/// balances. Pass an explicit fallback where zero is not a safe default.
Decimal readDecimal(Object? json, String key, {Decimal? fallback}) {
  return readDecimalOrNull(json, key) ?? fallback ?? Decimal.zero;
}

/// Like [readDecimal] but returns `null` when the value is missing or
/// malformed, for optional amounts such as a contract amount.
Decimal? readDecimalOrNull(Object? json, String key) {
  if (json is! Map) return null;
  final raw = json[key];
  if (raw == null) return null;
  final parsed = Decimal.tryParse(raw.toString().trim());
  if (parsed == null) onMalformedDecimal(key, raw);
  return parsed;
}
