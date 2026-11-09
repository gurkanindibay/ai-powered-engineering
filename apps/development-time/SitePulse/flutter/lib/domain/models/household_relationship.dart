/// A household member's relationship (person module F5). The server stores the
/// [code]; screens show the Turkish [label].
enum HouseholdRelationship {
  spouse('SPOUSE', 'Eşi'),
  child('CHILD', 'Çocuğu'),
  parent('PARENT', 'Anne/Baba'),
  relative('RELATIVE', 'Akrabası'),
  other('OTHER', 'Diğer');

  final String code;
  final String label;
  const HouseholdRelationship(this.code, this.label);

  /// Reads a code or a label written by an older version; anything else is [other].
  static HouseholdRelationship fromValue(String? value) {
    final v = (value ?? '').trim();
    for (final r in values) {
      if (r.code == v.toUpperCase() || r.label == v) return r;
    }
    return switch (v) {
      'Eş' => spouse,
      'Kardeşi' || 'Kardeş' || 'Family' => relative,
      _ => other,
    };
  }

  /// The label for a stored value; text that is not a known value is shown as it is
  /// (for example the owner's own role line).
  static String labelFor(String? value) {
    final v = (value ?? '').trim();
    if (v.isEmpty) return other.label;
    final known = values.where((r) => r.code == v.toUpperCase() || r.label == v);
    return known.isEmpty ? v : known.first.label;
  }
}
