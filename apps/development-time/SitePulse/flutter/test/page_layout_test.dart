@Tags(['ui'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sitepulse/domain/models/auth_models.dart';
import 'package:sitepulse/ui/dashboard/dashboard_controller.dart';
import 'package:sitepulse/ui/dashboard/dashboard_screen.dart';
import 'package:sitepulse/ui/design_system/sp_page_header.dart';
import 'package:sitepulse/ui/theme/app_theme.dart';

import 'test_fixtures.dart';

void main() {
  for (final width in [320.0, 390.0, 1400.0]) {
    testWidgets(
      'manager destinations share top context and boxed identity at $width',
      (tester) async {
        tester.view.physicalSize = Size(width, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final controller = DashboardController(isTestMode: true);
        controller.loadTestFixtures();
        controller.switchSessionRole(UserRole.siteManager);
        addTearDown(controller.dispose);
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.dark(),
            home: DashboardScreen(controller: controller),
          ),
        );
        await tester.pumpAndSettle();
        final initialHeaderTop = tester
            .getTopLeft(find.byType(SpPageHeader))
            .dy;
        expect(find.text('Yönetim Paneli'), findsOneWidget);

        for (final destination in [
          'Aidat Yönetimi',
          'Sakinler & Malikler',
          'Ana Sayfa',
        ]) {
          await tester.tap(find.text(destination));
          await tester.pumpAndSettle();
          expect(find.byType(SpPageHeader), findsOneWidget);
          expect(
            tester.getTopLeft(find.byType(SpPageHeader)).dy,
            initialHeaderTop,
          );
          expect(find.text('Kendi Dairem (Kat Maliki)'), findsOneWidget);
          expect(tester.takeException(), isNull);
          if (destination == 'Aidat Yönetimi') {
            expect(find.text('Aidat ve Tahsilat Yönetimi'), findsOneWidget);
            expect(
              tester.getTopLeft(find.byKey(const Key('segment_tab_0'))).dy,
              lessThan(
                tester
                    .getTopLeft(find.textContaining('Tahsilat Performansı'))
                    .dy,
              ),
            );
          }
        }
      },
    );
  }
}
