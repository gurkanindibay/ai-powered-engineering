import 'dart:async';

import 'package:flutter/material.dart';

import '../../domain/repositories/person_repository.dart';
import '../../domain/services/person_directory_api.dart';
import '../../testing/test_id.dart';
import '../components/app_fullscreen_page.dart';
import '../design_system/sp_guidance_card.dart';
import '../design_system/sp_tone.dart';

/// The only person component that owns editable identity fields.
class SpPersonForm extends StatefulWidget {
  final PersonRepository repository;
  final PersonSummary? person;
  final String initialQuery;
  final ValueChanged<PersonSummary>? onSaved;

  const SpPersonForm({
    super.key,
    required this.repository,
    this.person,
    this.initialQuery = '',
    this.onSaved,
  });

  @override
  State<SpPersonForm> createState() => _SpPersonFormState();
}

class _SpPersonFormState extends State<SpPersonForm> {
  late final TextEditingController _name;
  late final TextEditingController _phone;
  late final TextEditingController _email;
  Timer? _duplicateTimer;
  List<DuplicateCandidate> _duplicates = [];
  String? _error;
  bool _saving = false;
  bool _checkingDuplicates = false;
  bool _confirmDistinct = false;
  int _request = 0;

  @override
  void initState() {
    super.initState();
    final person = widget.person;
    final query = widget.initialQuery.trim();
    final digitsOnly =
        query.isNotEmpty &&
        query.replaceAll(RegExp(r'\D'), '').length == query.length;
    _name = TextEditingController(
      text:
          person?.fullName ?? (query.contains('@') || digitsOnly ? '' : query),
    );
    _phone = TextEditingController(
      text: person?.phone ?? (digitsOnly ? query : ''),
    );
    _email = TextEditingController(
      text: person?.email ?? (query.contains('@') ? query : ''),
    );
    if (person == null && query.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _checkDuplicates());
    }
  }

  @override
  void dispose() {
    _duplicateTimer?.cancel();
    _name.dispose();
    _phone.dispose();
    _email.dispose();
    super.dispose();
  }

  void _checkDuplicates() {
    _duplicateTimer?.cancel();
    final request = ++_request;
    final fullName = _name.text.trim();
    if (_name.text.trim().isEmpty) {
      setState(() {
        _duplicates = [];
        _checkingDuplicates = false;
      });
      return;
    }
    final email = _email.text.trim();
    final phone = _phone.text.trim();
    setState(() {
      _duplicates = [];
      _checkingDuplicates = true;
    });
    _duplicateTimer = Timer(const Duration(milliseconds: 350), () async {
      try {
        final found = await widget.repository.findDuplicates(
          fullName: fullName,
          email: email.isEmpty ? null : email,
          phone: phone.isEmpty ? null : phone,
          excludePersonId: widget.person?.personId,
        );
        if (mounted && request == _request) {
          setState(() {
            _duplicates = found;
            _checkingDuplicates = false;
          });
        }
      } catch (_) {
        if (mounted && request == _request) {
          setState(() => _checkingDuplicates = false);
        }
      }
    });
  }

  Future<void> _save() async {
    if (_checkingDuplicates) {
      setState(
        () => _error = 'Benzer kişi kontrolünün tamamlanmasını bekleyin.',
      );
      return;
    }
    if (_name.text.trim().isEmpty) {
      setState(() => _error = 'Ad soyad gerekli.');
      return;
    }
    if (_duplicates.any(
      (candidate) => candidate.reasons.any((reason) => reason == 'SAME_EMAIL'),
    )) {
      setState(
        () => _error =
            'Bu e-posta başka bir kişide kayıtlı. Mevcut kişiyi seçin.',
      );
      return;
    }
    if (_duplicates.isNotEmpty && !_confirmDistinct) {
      setState(
        () => _error = 'Benzer kişi bulundu. Mevcut kişiyi kullanın veya farklı kişi olduğunu onaylayın.',
      );
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final person = widget.person == null
          ? await widget.repository.create(
              fullName: _name.text.trim(),
              phone: _phone.text.trim().isEmpty ? null : _phone.text.trim(),
              email: _email.text.trim().isEmpty ? null : _email.text.trim(),
              confirmDistinct: _confirmDistinct,
            )
          : await widget.repository.update(
              widget.person!.personId,
              version: widget.person!.version,
              fullName: _name.text.trim(),
              phone: _phone.text.trim().isEmpty ? null : _phone.text.trim(),
              email: _email.text.trim().isEmpty ? null : _email.text.trim(),
            );
      if (!mounted) return;
      widget.onSaved?.call(person);
      Navigator.pop(context, person);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => AppFullscreenPage(
    title: widget.person == null ? 'Yeni kişi' : 'Kişiyi düzenle',
    subtitle: widget.person == null
        ? 'Yeni kayıt oluşturmadan önce benzer kişileri kontrol edin.'
        : null,
    bottomBar: AppFullscreenPage.buildBottomBar(
      context: context,
      children: [
        OutlinedButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('Geri dön'),
        ),
        testId(
          'person_form_save',
          FilledButton(
            onPressed: _saving ? null : _save,
            child: Text(_saving ? 'Kaydediliyor…' : 'Kaydet'),
          ),
        ),
      ],
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        testId(
          'person_form_name',
          TextField(
            key: const Key('person_form_name'),
            controller: _name,
            onChanged: (_) => _checkDuplicates(),
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(
              labelText: 'Ad soyad',
              prefixIcon: Icon(Icons.person_outline),
            ),
          ),
        ),
        const SizedBox(height: 12),
        testId(
          'person_form_phone',
          TextField(
            key: const Key('person_form_phone'),
            controller: _phone,
            onChanged: (_) => _checkDuplicates(),
            keyboardType: TextInputType.phone,
            decoration: const InputDecoration(
              labelText: 'Telefon',
              prefixIcon: Icon(Icons.phone_outlined),
            ),
          ),
        ),
        const SizedBox(height: 12),
        testId(
          'person_form_email',
          TextField(
            key: const Key('person_form_email'),
            controller: _email,
            onChanged: (_) => _checkDuplicates(),
            keyboardType: TextInputType.emailAddress,
            decoration: const InputDecoration(
              labelText: 'E-posta',
              prefixIcon: Icon(Icons.email_outlined),
            ),
          ),
        ),
        const SizedBox(height: 16),
        if (_checkingDuplicates)
          const LinearProgressIndicator(
            semanticsLabel: 'Benzer kişiler aranıyor',
          ),
        for (final candidate in _duplicates)
          ListTile(
            leading: const Icon(Icons.person_search_outlined),
            title: Text(candidate.person.fullName),
            subtitle: Text('Benzerlik: ${candidate.reasonText}'),
            trailing: TextButton(
              onPressed: () => Navigator.pop(context, candidate.person),
              child: const Text('Kullan'),
            ),
          ),
        if (_duplicates.isNotEmpty &&
            !_duplicates.any((c) => c.reasons.contains('SAME_EMAIL')))
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            value: _confirmDistinct,
            onChanged: (value) =>
                setState(() => _confirmDistinct = value ?? false),
            title: const Text('Bu farklı bir kişi'),
            subtitle: const Text('Bu tercih kaydedilir ve denetlenebilir.'),
          ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          SpGuidanceCard(
            icon: Icons.error_outline,
            title: 'Kayıt yapılamadı',
            message: _error!,
            tone: SpTone.danger,
          ),
        ],
      ],
    ),
  );
}
