import 'package:flutter/material.dart';

import '../../domain/services/api_client.dart';
import '../../domain/services/person_directory_api.dart';
import '../../domain/validation/person_validators.dart';
import '../../testing/test_id.dart';
import '../components/sp_dialog_pages.dart';
import '../design_system/sp_feedback.dart';
import '../theme/app_theme.dart';

/// Edits how the site reaches a person (person module F7). Pops with the saved
/// preferences, or `null` when cancelled.
class PersonPreferencesPage extends StatefulWidget {
  final int personId;
  final ContactPreferences initial;
  final PersonDirectoryApi api;

  const PersonPreferencesPage({
    super.key,
    required this.personId,
    required this.initial,
    this.api = const PersonDirectoryApi(),
  });

  @override
  State<PersonPreferencesPage> createState() => _PersonPreferencesPageState();
}

class _PersonPreferencesPageState extends State<PersonPreferencesPage> {
  final _form = GlobalKey<FormState>();
  late String _channel = widget.initial.channel;
  late String _language = widget.initial.language;
  late final _name = TextEditingController(text: widget.initial.emergencyName ?? '');
  late final _phone = TextEditingController(text: widget.initial.emergencyPhone ?? '');
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!(_form.currentState?.validate() ?? false)) return;
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _saving = true);
    try {
      final saved = await widget.api.updatePreferences(
        widget.personId,
        ContactPreferences(
          channel: _channel,
          language: _language,
          emergencyName: _name.text.trim().isEmpty ? null : _name.text.trim(),
          emergencyPhone: _phone.text.trim().isEmpty ? null : _phone.text.trim(),
        ),
      );
      navigator.pop(saved);
    } on ApiException catch (e) {
      messenger.showSnackBar(spSnackBar(kind: ToastKind.error, content: Text(e.message)));
    } catch (_) {
      messenger.showSnackBar(spSnackBar(kind: ToastKind.error, content: const Text('Tercihler kaydedilemedi.')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SpDialogPage(
      title: 'İletişim tercihleri',
      child: Form(
        key: _form,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            testId('person_pref_channel', DropdownButtonFormField<String>(
              key: const Key('person_pref_channel'),
              initialValue: _channel,
              decoration: const InputDecoration(labelText: 'Tercih edilen kanal'),
              items: [
                for (final e in ContactPreferences.channels.entries)
                  DropdownMenuItem(value: e.key, child: Text(e.value)),
              ],
              onChanged: (v) => setState(() => _channel = v ?? _channel),
            )),
            const SizedBox(height: AppSpacing.md),
            testId('person_pref_language', DropdownButtonFormField<String>(
              key: const Key('person_pref_language'),
              initialValue: _language,
              decoration: const InputDecoration(labelText: 'Dil'),
              items: [
                for (final e in ContactPreferences.languages.entries)
                  DropdownMenuItem(value: e.key, child: Text(e.value)),
              ],
              onChanged: (v) => setState(() => _language = v ?? _language),
            )),
            const SizedBox(height: AppSpacing.xl),
            Text('Acil durumda aranacak kişi', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: AppSpacing.sm),
            testId('person_pref_emergency_name', TextFormField(
              key: const Key('person_pref_emergency_name'),
              controller: _name,
              decoration: const InputDecoration(labelText: 'Ad soyad (isteğe bağlı)'),
              validator: (v) => (v ?? '').trim().isEmpty && _phone.text.trim().isNotEmpty
                  ? 'Telefonu girdiyseniz adı da girin.'
                  : null,
            )),
            const SizedBox(height: AppSpacing.md),
            testId('person_pref_emergency_phone', TextFormField(
              key: const Key('person_pref_emergency_phone'),
              controller: _phone,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(labelText: 'Telefon (isteğe bağlı)'),
              validator: (v) {
                if ((v ?? '').trim().isEmpty) {
                  return _name.text.trim().isNotEmpty ? 'Adı girdiyseniz telefonu da girin.' : null;
                }
                return validateTrMobile(v);
              },
            )),
            const SizedBox(height: AppSpacing.xl),
            testId('person_pref_save_btn', FilledButton(
              key: const Key('person_pref_save_btn'),
              onPressed: _saving ? null : _save,
              child: Text(_saving ? 'Kaydediliyor…' : 'Kaydet'),
            )),
          ],
        ),
      ),
    );
  }
}
