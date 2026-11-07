import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Logs out the way a user does: avatar → profile sheet → "Çıkış Yap" → confirm.
Future<void> logOutThroughProfile(WidgetTester tester) async {
  final avatar = find.byTooltip('Profil, tema ve çıkış');
  expect(avatar, findsOneWidget);
  await tester.tap(avatar);
  await tester.pumpAndSettle();

  // Let the "logged in as ..." toast (4 s) close so it does not cover the button.
  await tester.pump(const Duration(seconds: 5));
  await tester.pumpAndSettle();

  final logout = find.byKey(const Key('btn_logout'));
  await tester.ensureVisible(logout);
  await tester.pumpAndSettle();
  await tester.tap(logout);
  await tester.pumpAndSettle();

  // Logout asks first and names the consequence.
  expect(find.text('Çıkış yapılsın mı?'), findsOneWidget);
  await tester.tap(find.byKey(const Key('btn_confirm_logout')));
  await tester.pumpAndSettle();
}
