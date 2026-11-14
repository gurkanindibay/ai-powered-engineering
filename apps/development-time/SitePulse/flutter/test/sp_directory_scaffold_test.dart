import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sitepulse/ui/residents/sp_directory_scaffold.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget buildDirectory(List<String> items) => MaterialApp(
    restorationScopeId: 'directory_test',
    home: Scaffold(
      body: SpDirectoryScaffold<String>(
        restorationId: 'directory',
        resultKey: items.length,
        items: items,
        header: const Text('Directory filters'),
        emptyState: const Text('No matches'),
        itemBuilder: (context, item, index) =>
            ListTile(key: Key('directory_row_$item'), title: Text(item)),
      ),
    ),
  );

  // covers: SC-12-02-01
  testWidgets(
    'when a directory page advances then it shows the next page range',
    (tester) async {
      final items = List<String>.generate(40, (index) => 'Unit ${index + 1}');
      await tester.pumpWidget(buildDirectory(items));
      await tester.pumpAndSettle();

      expect(find.text('1 / 2'), findsOneWidget);
      await tester.tap(find.byTooltip('Sonraki sayfa'));
      await tester.pumpAndSettle();

      expect(find.text('2 / 2'), findsOneWidget);
      expect(find.text('Unit 26'), findsOneWidget);
    },
  );

  // covers: SC-12-02-02
  testWidgets(
    'when page density changes then the directory page count updates',
    (tester) async {
      final items = List<String>.generate(40, (index) => 'Unit ${index + 1}');
      await tester.pumpWidget(buildDirectory(items));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(DropdownButton<int>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('50 / sayfa').last);
      await tester.pumpAndSettle();

      expect(find.text('1 / 1'), findsOneWidget);
    },
  );

  // covers: SC-12-02-08
  testWidgets(
    'when the app restores then the selected directory page and density persist',
    (tester) async {
      final items = List<String>.generate(120, (index) => 'Unit ${index + 1}');
      await tester.pumpWidget(buildDirectory(items));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(DropdownButton<int>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('50 / sayfa').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Sonraki sayfa'));
      await tester.pumpAndSettle();
      expect(find.text('2 / 3'), findsOneWidget);

      await tester.restartAndRestore();
      await tester.pumpAndSettle();

      expect(find.byType(DropdownButton<int>), findsOneWidget);
      expect(tester.widget<DropdownButton<int>>(find.byType(DropdownButton<int>)).value, 50);
      expect(find.text('2 / 3'), findsOneWidget);
      expect(find.text('Unit 51'), findsOneWidget);
    },
  );

  // covers: SC-12-02-03
  testWidgets(
    'when the viewport is narrow then the pager wraps without overflow',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        buildDirectory(
          List<String>.generate(35, (index) => 'Unit ${index + 1}'),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byType(SpDirectoryScaffold<String>), findsOneWidget);
    },
  );

  // covers: SC-12-02-04
  testWidgets(
    'when a directory contains one or ten thousand units then only visible rows are built',
    (tester) async {
      for (final count in [1000, 10000]) {
        var builtRows = 0;
        final items = List<int>.generate(count, (index) => index);
        await tester.pumpWidget(
          MaterialApp(
            restorationScopeId: 'directory_scale_test',
            home: Scaffold(
              body: SpDirectoryScaffold<int>(
                key: ValueKey('scale_$count'),
                restorationId: 'directory_scale_$count',
                items: items,
                header: const Text('Directory filters'),
                emptyState: const Text('No matches'),
                itemBuilder: (context, item, index) {
                  builtRows++;
                  return ListTile(title: Text('Unit $item'));
                },
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(builtRows, lessThan(25));
        expect(find.text('Unit ${count - 1}'), findsNothing);
      }
    },
  );
}
