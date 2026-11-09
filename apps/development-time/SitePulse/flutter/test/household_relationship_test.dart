@Tags(['residents'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sitepulse/domain/models/household_relationship.dart';
import 'package:sitepulse/ui/residents/household_relationship_items.dart';

/// Person module F5: relationships travel as codes and are shown as labels.
void main() {
  test('codes and labels round-trip, older labels are read, unknown text is OTHER', () {
    for (final r in HouseholdRelationship.values) {
      expect(HouseholdRelationship.fromValue(r.code), r);
      expect(HouseholdRelationship.fromValue(r.label), r);
    }
    expect(HouseholdRelationship.fromValue('Kardeşi'), HouseholdRelationship.relative);
    expect(HouseholdRelationship.fromValue('Ev Sakini'), HouseholdRelationship.other);
    expect(HouseholdRelationship.fromValue(null), HouseholdRelationship.other);
  });

  test('labels: a code shows its Turkish label; other text is shown as it is', () {
    expect(HouseholdRelationship.labelFor('CHILD'), 'Çocuğu');
    expect(HouseholdRelationship.labelFor('Kat Maliki (Ev Sahibi)'), 'Kat Maliki (Ev Sahibi)');
    expect(HouseholdRelationship.labelFor(''), 'Diğer');
  });

  testWidgets('the picker offers exactly the five codes and accepts a stored code', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: DropdownButtonFormField<String>(
          initialValue: HouseholdRelationship.fromValue('PARENT').code,
          items: householdRelationshipItems(),
          onChanged: (_) {},
        ),
      ),
    ));
    expect(find.text('Anne/Baba'), findsOneWidget);
    expect(householdRelationshipItems().map((i) => i.value), ['SPOUSE', 'CHILD', 'PARENT', 'RELATIVE', 'OTHER']);
  });
}
