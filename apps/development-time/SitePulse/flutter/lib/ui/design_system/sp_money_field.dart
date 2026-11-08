import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../domain/formatting/money_formatter.dart';

/// Result of reading an amount typed by the user.
///
/// Keeps "empty", "not an amount" and "a valid zero" distinct so callers never
/// mistake bad input for `Decimal.zero`.
class MoneyInput {
  final String text;
  final Decimal? amount;

  const MoneyInput._(this.text, this.amount);

  /// Parses [text] with [MoneyFormatter.tryParse], the single parsing rule
  /// for typed amounts (`1.423,33`, `1423,33`, `1423.33`, `₺1.423`).
  factory MoneyInput.parse(String text) => MoneyInput._(text, MoneyFormatter.tryParse(text));

  bool get isEmpty => text.trim().isEmpty;
  bool get isValid => amount != null;

  /// More than two fractional digits cannot be represented in kuruş.
  bool get hasSubKurusDigits => (amount?.scale ?? 0) > 2;
}

/// Standard validation messages for [validateMoneyInput].
class MoneyInputMessages {
  static const required = 'Tutar zorunludur';
  static const invalid = 'Geçerli bir tutar girin';
  static const positive = 'Tutar sıfırdan büyük olmalıdır';
  static const scale = 'Tutar en fazla 2 kuruş hanesi içerebilir';
}

/// Shared validation for amount text. Returns an error message or `null`.
///
/// Business limits (maximum payable amount, allocation rules) stay with the
/// caller and can be layered on through [extra].
String? validateMoneyInput(
  String? text, {
  bool required = true,
  bool positive = true,
  String? Function(Decimal amount)? extra,
  String requiredMessage = MoneyInputMessages.required,
  String invalidMessage = MoneyInputMessages.invalid,
}) {
  final input = MoneyInput.parse(text ?? '');
  if (input.isEmpty) return required ? requiredMessage : null;
  final amount = input.amount;
  if (amount == null) return invalidMessage;
  if (input.hasSubKurusDigits) return MoneyInputMessages.scale;
  if (positive && amount <= Decimal.zero) return MoneyInputMessages.positive;
  return extra?.call(amount);
}

/// Characters a user may type into an amount field (opt-in through
/// [SpMoneyFormField.restrictInput]).
final moneyInputFormatter = FilteringTextInputFormatter.allow(RegExp(r'[0-9.,₺ -]'));

/// A [TextFormField] for Turkish Lira amounts.
///
/// Parses with [MoneyFormatter.tryParse], reports the parsed value through
/// [onAmountChanged] (`null` while the text is empty or not an amount), and
/// never reformats while the user types. Money never passes through `double`.
class SpMoneyFormField extends StatelessWidget {
  final TextEditingController? controller;
  final InputDecoration decoration;
  final bool required;
  final bool positive;
  final String? Function(Decimal amount)? extraValidator;
  final ValueChanged<Decimal?>? onAmountChanged;
  final TextStyle? style;
  final bool autofocus;
  final bool enabled;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onFieldSubmitted;
  final AutovalidateMode? autovalidateMode;
  final String requiredMessage;
  final String invalidMessage;

  /// Drops characters that can never be part of an amount while typing.
  /// Off by default so pasted text is validated (and reported) rather than
  /// silently stripped.
  final bool restrictInput;

  const SpMoneyFormField({
    super.key,
    this.controller,
    this.decoration = const InputDecoration(),
    this.required = true,
    this.positive = true,
    this.extraValidator,
    this.onAmountChanged,
    this.style,
    this.autofocus = false,
    this.enabled = true,
    this.textInputAction,
    this.onFieldSubmitted,
    this.autovalidateMode,
    this.requiredMessage = MoneyInputMessages.required,
    this.invalidMessage = MoneyInputMessages.invalid,
    this.restrictInput = false,
  });

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      decoration: decoration,
      style: style,
      autofocus: autofocus,
      enabled: enabled,
      textInputAction: textInputAction,
      onFieldSubmitted: onFieldSubmitted,
      autovalidateMode: autovalidateMode,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: restrictInput ? [moneyInputFormatter] : null,
      validator: (v) => validateMoneyInput(
        v,
        required: required,
        positive: positive,
        extra: extraValidator,
        requiredMessage: requiredMessage,
        invalidMessage: invalidMessage,
      ),
      onChanged: onAmountChanged == null ? null : (v) => onAmountChanged!(MoneyInput.parse(v).amount),
    );
  }
}
