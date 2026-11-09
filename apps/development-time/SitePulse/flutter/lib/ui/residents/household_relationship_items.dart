import 'package:flutter/material.dart';

import '../../domain/models/household_relationship.dart';

/// Dropdown entries for a household relationship picker: codes as values,
/// Turkish labels as text. Use with `HouseholdRelationship.fromValue(x).code`
/// as the field's value so a stored code always matches an entry.
List<DropdownMenuItem<String>> householdRelationshipItems() => [
      for (final r in HouseholdRelationship.values) DropdownMenuItem(value: r.code, child: Text(r.label)),
    ];
