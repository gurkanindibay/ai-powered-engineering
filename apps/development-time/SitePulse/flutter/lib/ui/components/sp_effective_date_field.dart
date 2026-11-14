import 'package:flutter/material.dart';

/// Formats a date as `yyyy-MM-dd`, the wire format of every effective date.
String formatEffectiveDate(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

/// A read-only date field that opens a picker. The latest selectable date is
/// today: an effective date is never in the future (EPIC-08 STORY-08-10).
class SpEffectiveDateField extends StatelessWidget {
  final DateTime value;
  final ValueChanged<DateTime> onChanged;
  final String label;

  const SpEffectiveDateField({
    super.key,
    required this.value,
    required this.onChanged,
    this.label = 'Geçerlilik Tarihi (Effective Date)',
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () async {
        final now = DateTime.now();
        final today = DateTime(now.year, now.month, now.day);
        final picked = await showDatePicker(
          context: context,
          initialDate: value.isAfter(today) ? today : value,
          firstDate: DateTime(2000),
          lastDate: today,
        );
        if (picked != null) onChanged(picked);
      },
      child: InputDecorator(
        decoration: InputDecoration(labelText: label, suffixIcon: const Icon(Icons.calendar_today, size: 18)),
        child: Text(formatEffectiveDate(value)),
      ),
    );
  }
}
