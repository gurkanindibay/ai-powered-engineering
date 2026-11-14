import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sitepulse/domain/models/dues_models.dart';
import 'package:sitepulse/ui/residents/unit_directory_row.dart';

void main() {
  // covers: SC-12-02-07
  testWidgets('unit directory row adapts from 320 to 1440 pixels', (tester) async {
    for (final width in [320.0, 720.0, 1440.0]) {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      await tester.pumpWidget(const SizedBox.shrink());
      final unit = HomeOwnerItem(
        unitId: 'unit-1',
        siteId: 'site-1',
        block: 'A Blok',
        unitNo: 12,
        floor: 3,
        ownerFullName: 'Long owner name',
        email: '',
        phone: '',
        landShare: '1/24',
        monthlyDues: Decimal.zero,
        isResident: false,
        mustChangePassword: false,
        createdAt: DateTime(2026),
      );

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: UnitDirectoryRow(
            unit: unit,
            onActions: () {},
            onDetails: () {},
          ),
        ),
      ));

      expect(find.text('A Blok 12'), findsOneWidget);
      expect(find.byKey(const Key('module_unit_actions_unit-1')), findsOneWidget);
      expect(find.byKey(const Key('module_unit_details_unit-1')), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  });
}
