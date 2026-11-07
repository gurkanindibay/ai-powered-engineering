import 'dart:math' as math;

import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sitepulse/ui/design_system/money_formatter.dart';
import 'package:sitepulse/ui/design_system/sp_feedback.dart';
import 'package:sitepulse/ui/theme/app_theme.dart';

Decimal d(String v) => Decimal.parse(v);

/// WCAG 2.1 relative luminance and contrast ratio.
double _luminance(Color c) {
  double channel(double v) => v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b);
}

double contrast(Color a, Color b) {
  final la = _luminance(a), lb = _luminance(b);
  final hi = math.max(la, lb), lo = math.min(la, lb);
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  group('MoneyFormatter (finding 3: one format, Decimal only)', () {
    test('formats Turkish Lira with dot grouping and comma kuruş', () {
      expect(MoneyFormatter.format(d('1423.33')), '₺1.423,33');
      expect(MoneyFormatter.format(d('0')), '₺0,00');
      expect(MoneyFormatter.format(d('7')), '₺7,00');
      expect(MoneyFormatter.format(d('999.9')), '₺999,90');
      expect(MoneyFormatter.format(d('1000')), '₺1.000,00');
      expect(MoneyFormatter.format(d('1234567.89')), '₺1.234.567,89');
    });

    test('keeps precision on amounts a double cannot hold', () {
      // 2^53 + 1 is not representable as a double; the formatter must not round it.
      expect(MoneyFormatter.format(d('9007199254740993.01')), '₺9.007.199.254.740.993,01');
    });

    test('rounds half kuruş away from zero, without double drift', () {
      expect(MoneyFormatter.format(d('1.005')), '₺1,01');
      expect(MoneyFormatter.format(d('2.675')), '₺2,68');
      expect(MoneyFormatter.format(d('23.333333')), '₺23,33');
    });

    test('formats negatives and signed ledger values', () {
      expect(MoneyFormatter.format(d('-1460.67')), '-₺1.460,67');
      expect(MoneyFormatter.formatSigned(d('500')), '+₺500,00');
      expect(MoneyFormatter.formatSigned(d('-500')), '-₺500,00');
      expect(MoneyFormatter.formatCredit(d('-576.67')), '+₺576,67');
      expect(MoneyFormatter.formatPlain(d('1423.33')), '1.423,33');
      expect(formatTry(d('1400.55') * d('2')), '₺2.801,10');
    });

    test('parses what people type', () {
      expect(MoneyFormatter.tryParse('1.423,33'), d('1423.33'));
      expect(MoneyFormatter.tryParse('1423,33'), d('1423.33'));
      expect(MoneyFormatter.tryParse('1423.33'), d('1423.33'));
      expect(MoneyFormatter.tryParse('₺ 1.400'), d('1400'));
      expect(MoneyFormatter.tryParse('1.234.567'), d('1234567'));
      expect(MoneyFormatter.tryParse(''), isNull);
      expect(MoneyFormatter.tryParse('on bin'), isNull);
      expect(MoneyFormatter.tryParse('1,2,3'), isNull);
    });

    test('format and parse round-trip', () {
      for (final v in ['0.01', '1423.33', '1000000', '42000.5']) {
        expect(MoneyFormatter.tryParse(MoneyFormatter.format(d(v))), d(v));
      }
    });
  });

  group('Colour tokens reach WCAG AA 4.5:1 (finding 2)', () {
    const white = Colors.white;
    test('solid fills carry white text', () {
      for (final fill in [
        AppColors.primaryFill,
        AppColors.successFill,
        AppColors.warningFill,
        AppColors.dangerFill,
        AppColors.infoFill,
        AppColors.neutralFill,
        AppColors.purpleFill,
      ]) {
        expect(contrast(white, fill), greaterThanOrEqualTo(4.5), reason: 'white on $fill');
      }
    });

    test('status text on light surfaces', () {
      for (final text in [
        AppColors.primaryTextLight,
        AppColors.successTextLight,
        AppColors.warningTextLight,
        AppColors.dangerTextLight,
        AppColors.lightTextPrimary,
        AppColors.lightTextSecondary,
      ]) {
        for (final bg in [AppColors.lightSurface, AppColors.lightBackground, AppColors.lightCard]) {
          expect(contrast(text, bg), greaterThanOrEqualTo(4.5), reason: '$text on $bg');
        }
      }
    });

    test('status text on dark surfaces', () {
      for (final text in [
        AppColors.primaryTextDark,
        AppColors.successTextDark,
        AppColors.warningTextDark,
        AppColors.dangerTextDark,
        AppColors.darkTextPrimary,
        AppColors.darkTextSecondary,
      ]) {
        for (final bg in [AppColors.darkSurface, AppColors.darkBackground, AppColors.darkCard]) {
          expect(contrast(text, bg), greaterThanOrEqualTo(4.5), reason: '$text on $bg');
        }
      }
    });

    test('the old bright tones are kept for icons and fills only (they fail as text on white)', () {
      expect(contrast(white, AppColors.accentGreen), lessThan(4.5));
      expect(contrast(white, AppColors.accentOrange), lessThan(4.5));
    });

    test('theme colour schemes use the accessible pairs', () {
      final light = AppTheme.light().colorScheme;
      final dark = AppTheme.dark().colorScheme;
      expect(contrast(light.onPrimary, light.primary), greaterThanOrEqualTo(4.5));
      expect(contrast(dark.onPrimary, dark.primary), greaterThanOrEqualTo(4.5));
      expect(contrast(light.onSurface, light.surface), greaterThanOrEqualTo(4.5));
      expect(contrast(dark.onSurfaceVariant, dark.surface), greaterThanOrEqualTo(4.5));
      expect(AppTheme.light().extension<StatusColors>(), isNotNull);
    });
  });

  group('Type scale (finding 4)', () {
    test('no text style in the theme is below 12 px', () {
      for (final theme in [AppTheme.light(), AppTheme.dark()]) {
        final t = theme.textTheme;
        for (final style in [
          t.displaySmall, t.headlineSmall, t.titleLarge, t.titleMedium, t.titleSmall,
          t.bodyLarge, t.bodyMedium, t.bodySmall, t.labelLarge, t.labelMedium, t.labelSmall,
        ]) {
          expect(style?.fontSize, greaterThanOrEqualTo(12));
        }
        expect(t.bodyMedium?.fontSize, 14);
        expect(t.displaySmall?.fontFeatures, contains(const FontFeature.tabularFigures()));
      }
    });
  });

  group('Toasts (finding 12: errors never look like success)', () {
    test('kind comes from colour, then from wording', () {
      expect(inferToastKind(backgroundColor: AppColors.accentGreen), ToastKind.success);
      expect(inferToastKind(backgroundColor: AppColors.accentRed), ToastKind.error);
      expect(inferToastKind(backgroundColor: AppColors.accentOrange), ToastKind.warning);
      expect(inferToastKind(message: 'Kayıt sırasında bir hata oluştu'), ToastKind.error);
      expect(inferToastKind(message: 'Lütfen e-posta adresinizi giriniz'), ToastKind.error);
      expect(inferToastKind(message: 'Sakin başarıyla eklendi'), ToastKind.success);
      expect(inferToastKind(message: 'Ekstre yükleniyor'), ToastKind.info);
    });

    test('each kind has its own fill and icon; errors stay until dismissed', () {
      final fills = ToastKind.values.map((k) => k.fill).toSet();
      final icons = ToastKind.values.map((k) => k.icon).toSet();
      expect(fills.length, ToastKind.values.length);
      expect(icons.length, ToastKind.values.length);
      final error = spSnackBar(kind: ToastKind.error, content: const Text('x'));
      final ok = spSnackBar(kind: ToastKind.success, content: const Text('x'));
      expect(error.showCloseIcon, isTrue);
      expect(error.duration, greaterThan(const Duration(hours: 1)));
      expect(ok.duration, const Duration(seconds: 4));
      for (final k in ToastKind.values) {
        expect(contrast(Colors.white, k.fill), greaterThanOrEqualTo(4.5));
      }
    });

    testWidgets('a toast announces its kind to screen readers', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(onPressed: () => SpToast.error(context, 'Kayıt başarısız'), child: const Text('go')),
          ),
        ),
      ));
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      expect(find.text('Kayıt başarısız'), findsOneWidget);
      expect(find.byIcon(Icons.error_rounded), findsOneWidget);
      expect(find.bySemanticsLabel('Hata: Kayıt başarısız'), findsOneWidget);
    });
  });
}
