import 'package:flutter/material.dart';

import '../../domain/models/person_ref.dart';
import '../../domain/repositories/person_repository.dart';
import '../../domain/services/person_directory_api.dart';
import '../../testing/test_id.dart';
import 'sp_person_card.dart';
import 'sp_person_picker.dart';

/// A reusable form field that chooses an existing person or creates a card.
class SpPersonField extends StatefulWidget {
  final PersonRepository repository;
  final String? roleContext;
  final String? unitId;
  final PersonRef? value;
  final PersonSummary? initialPerson;
  final ValueChanged<PersonRef?> onChanged;
  final VoidCallback? onOpenPerson;
  final String id;

  const SpPersonField({
    super.key,
    required this.repository,
    required this.onChanged,
    this.roleContext,
    this.unitId,
    this.value,
    this.initialPerson,
    this.onOpenPerson,
    this.id = 'sp_person_field',
  });

  @override
  State<SpPersonField> createState() => _SpPersonFieldState();
}

class _SpPersonFieldState extends State<SpPersonField> {
  PersonSummary? _person;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _person = widget.initialPerson;
    _loadCurrent();
  }

  @override
  void didUpdateWidget(covariant SpPersonField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value?.personId != widget.value?.personId) _loadCurrent();
  }

  Future<void> _loadCurrent() async {
    final id = widget.value?.personId;
    if (id == null || _person?.personId == id) return;
    setState(() => _loading = true);
    try {
      final person = await widget.repository.getById(id);
      if (mounted) {
        setState(() {
          _person = person;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _choose() async {
    final selected = await showSpPersonPicker(
      context: context,
      repository: widget.repository,
      roleContext: widget.roleContext,
      unitId: widget.unitId,
    );
    if (!mounted || selected == null) return;
    setState(() => _loading = true);
    try {
      final person = await widget.repository.getById(selected.personId!);
      if (!mounted) return;
      setState(() {
        _person = person;
        _loading = false;
      });
      widget.onChanged(selected);
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (_person != null)
        SpPersonCard(
          id: '${widget.id}_card',
          person: _person!,
          size: SpPersonCardSize.compact,
          onTap: widget.onOpenPerson,
        )
      else
        testId(
          widget.id,
          OutlinedButton.icon(
            key: Key(widget.id),
            onPressed: _loading ? null : _choose,
            icon: const Icon(Icons.person_search_outlined),
            label: Text(_loading ? 'Kişi yükleniyor…' : 'Kişi seç veya ekle'),
          ),
        ),
      if (_person != null)
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: _choose,
            icon: const Icon(Icons.swap_horiz),
            label: const Text('Değiştir'),
          ),
        ),
    ],
  );
}
