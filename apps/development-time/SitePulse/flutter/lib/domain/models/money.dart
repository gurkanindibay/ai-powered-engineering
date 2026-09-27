import 'package:decimal/decimal.dart';

/// High-precision Monetary Value Object adhering to workspace directives.
/// Guarantees zero floating-point arithmetic drift in financial operations.
class Money implements Comparable<Money> {
  final Decimal amount;
  final String currency;

  const Money._(this.amount, [this.currency = 'TRY']);

  factory Money.fromDecimal(Decimal amount, [String currency = 'TRY']) {
    return Money._(amount, currency);
  }

  factory Money.fromString(String amountStr, [String currency = 'TRY']) {
    return Money._(Decimal.parse(amountStr), currency);
  }

  factory Money.zero([String currency = 'TRY']) {
    return Money._(Decimal.zero, currency);
  }

  Money operator +(Money other) {
    assert(currency == other.currency, 'Cannot add different currencies');
    return Money._(amount + other.amount, currency);
  }

  Money operator -(Money other) {
    assert(currency == other.currency, 'Cannot subtract different currencies');
    return Money._(amount - other.amount, currency);
  }

  Money operator *(Decimal factor) {
    return Money._(amount * factor, currency);
  }

  @override
  int compareTo(Money other) {
    assert(currency == other.currency, 'Cannot compare different currencies');
    return amount.compareTo(other.amount);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Money &&
          runtimeType == other.runtimeType &&
          amount == other.amount &&
          currency == other.currency;

  @override
  int get hashCode => amount.hashCode ^ currency.hashCode;

  /// Returns formatted Turkish Lira string (e.g. "₺1423.33")
  String toFormattedString() {
    final fixedStr = amount.toStringAsFixed(2);
    return '₺$fixedStr';
  }

  @override
  String toString() => toFormattedString();
}
