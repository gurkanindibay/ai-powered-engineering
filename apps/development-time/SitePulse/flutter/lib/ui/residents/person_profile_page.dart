import 'package:flutter/material.dart';

import '../../domain/repositories/api_person_repository.dart';
import '../../domain/repositories/person_repository.dart';
import '../../domain/services/api_client.dart';
import '../../domain/services/person_directory_api.dart';
import '../../domain/validation/person_validators.dart';
import '../../testing/test_id.dart';
import '../components/app_fullscreen_page.dart';
import '../components/sp_dialog_pages.dart';
import '../components/step_up_prompt.dart';
import '../design_system/sp_feedback.dart';
import '../design_system/sp_guidance_card.dart';
import '../design_system/sp_status_badge.dart';
import '../design_system/sp_tone.dart';
import '../theme/app_theme.dart';
import 'activation_status.dart';
import 'person_preferences_page.dart';
import 'sp_person_form.dart';

/// One person: contact, login state and every unit they own, rent or live in, as a
/// timeline (person module U3/U4/U10).
class PersonProfilePage extends StatefulWidget {
  final int personId;
  final PersonDirectoryApi api;
  final PersonRepository repository;

  /// Opens the unit workspace of a unit row. Rows are plain text without it.
  final Future<void> Function(String unitId)? onOpenUnit;

  /// Starts a person-first role action (`TENANT`, `OWNER`, `MEMBER`): the caller selects
  /// the unit, the person stays fixed.
  final Future<void> Function(PersonSummary person, String role)? onGiveRole;

  /// Called after the card changed, so other views of the same person can reload.
  final Future<void> Function(PersonSummary person)? onChanged;

  const PersonProfilePage({
    super.key,
    required this.personId,
    this.api = const PersonDirectoryApi(),
    this.repository = const ApiPersonRepository(),
    this.onOpenUnit,
    this.onGiveRole,
    this.onChanged,
  });

  @override
  State<PersonProfilePage> createState() => _PersonProfilePageState();
}

class _PersonProfilePageState extends State<PersonProfilePage> {
  PersonProfile? _profile;
  String? _error;
  bool _resending = false;
  bool _savingId = false;
  bool _openingLogin = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final profile = await widget.api.profile(widget.personId);
      if (mounted) setState(() => _profile = profile);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = 'Sunucuya ulaşılamadı. Tekrar deneyin.');
    }
  }

  Future<void> _notifyChanged([PersonSummary? person]) async {
    final current = person ?? _profile?.person;
    if (current != null) await widget.onChanged?.call(current);
  }

  /// Edits name and contact. The change reaches every unit that shows this person.
  Future<void> _edit(PersonProfile profile) async {
    final saved = await AppFullscreenPage.push<PersonSummary>(
      context: context,
      builder: (_) => SpPersonForm(repository: widget.repository, person: profile.person),
    );
    if (saved == null || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      spSnackBar(kind: ToastKind.success, content: const Text('Kişi bilgileri kaydedildi.')),
    );
    await _load();
    await _notifyChanged(saved);
  }

  Future<void> _openLogin(PersonProfile profile) async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _openingLogin = true);
    try {
      final status = await widget.api.openLogin(profile.person.personId);
      messenger.showSnackBar(spSnackBar(
        kind: status == 'SENT' ? ToastKind.success : ToastKind.warning,
        content: Text(activationStatusMessage(status, profile.person.email)),
      ));
      await _load();
      await _notifyChanged();
    } on ApiException catch (e) {
      messenger.showSnackBar(spSnackBar(kind: ToastKind.error, content: Text(e.message)));
    } catch (_) {
      messenger.showSnackBar(spSnackBar(kind: ToastKind.error, content: const Text('Giriş hesabı açılamadı.')));
    } finally {
      if (mounted) setState(() => _openingLogin = false);
    }
  }

  Future<void> _resend(PersonProfile profile) async {
    final unit = profile.activationUnit;
    if (unit == null) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _resending = true);
    try {
      final status = await widget.api.resendActivation(unit.unitId, tenant: unit.relation == 'TENANT');
      messenger.showSnackBar(spSnackBar(
        kind: status == 'SENT' ? ToastKind.success : ToastKind.warning,
        content: Text(activationStatusMessage(status, profile.person.email)),
      ));
    } on ApiException catch (e) {
      messenger.showSnackBar(spSnackBar(kind: ToastKind.error, content: Text(e.message)));
    } catch (_) {
      messenger.showSnackBar(spSnackBar(kind: ToastKind.error, content: const Text('Bağlantı gönderilemedi.')));
    } finally {
      if (mounted) setState(() => _resending = false);
    }
  }

  /// F10: records or clears the national ID. The server asks for a fresh password check
  /// first; the change is audited and only a mask is ever shown again.
  Future<void> _editNationalId(PersonProfile profile, {bool clear = false}) async {
    final messenger = ScaffoldMessenger.of(context);
    String value = '';
    if (!clear) {
      final entered = await showSpTextPrompt(
        context: context,
        title: 'T.C. kimlik numarası',
        label: 'Kimlik numarası (11 hane)',
        message: 'Banka ödemelerini daireyle eşleştirmek için kullanılır. Numaranın yalnızca son 4 hanesi gösterilir.',
        submitLabel: 'Kaydet',
        minLength: 11,
        maxLines: 1,
      );
      if (entered == null || !mounted) return;
      final invalid = validateTckn(entered);
      if (invalid != null) {
        messenger.showSnackBar(spSnackBar(kind: ToastKind.error, content: Text(invalid)));
        return;
      }
      value = entered;
    }
    setState(() => _savingId = true);
    try {
      try {
        await widget.api.setNationalId(profile.person.personId, value);
      } on ApiException catch (e) {
        if (e.code != 'STEP_UP_REQUIRED' || !mounted) rethrow;
        final verified = await showStepUpPrompt(
          context,
          reason: 'Kimlik numarası bir kimlik bilgisidir. Değiştirmek için şifrenizi doğrulayın; işlem denetim kaydına yazılır.',
        );
        if (!verified) return;
        await widget.api.setNationalId(profile.person.personId, value);
      }
      messenger.showSnackBar(spSnackBar(
        kind: ToastKind.success,
        content: Text(clear ? 'Kimlik numarası kaldırıldı.' : 'Kimlik numarası kaydedildi.'),
      ));
      await _load();
    } on ApiException catch (e) {
      messenger.showSnackBar(spSnackBar(kind: ToastKind.error, content: Text(e.message)));
    } catch (_) {
      messenger.showSnackBar(spSnackBar(kind: ToastKind.error, content: const Text('Kimlik numarası kaydedilemedi.')));
    } finally {
      if (mounted) setState(() => _savingId = false);
    }
  }

  Future<void> _editPreferences(PersonProfile profile) async {
    final saved = await showSpPage<ContactPreferences>(
      context: context,
      builder: (_) => PersonPreferencesPage(
        personId: profile.person.personId,
        initial: profile.record.preferences,
        api: widget.api,
      ),
    );
    if (saved == null || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      spSnackBar(kind: ToastKind.success, content: const Text('İletişim tercihleri kaydedildi.')),
    );
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final profile = _profile;
    return AppFullscreenPage(
      title: profile?.person.fullName ?? 'Kişi',
      subtitle: profile == null ? null : personRoleLabel(profile.person.role),
      icon: const Icon(Icons.person_outline),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_error != null)
            SpGuidanceCard(icon: Icons.error_outline, title: 'Kişi yüklenemedi', message: _error!, tone: SpTone.danger)
          else if (profile == null)
            const Padding(padding: EdgeInsets.all(AppSpacing.xl), child: Center(child: CircularProgressIndicator(semanticsLabel: 'Yükleniyor')))
          else ...[
            _contact(context, profile.person, profile),
            const SizedBox(height: AppSpacing.lg),
            _login(context, profile),
            const SizedBox(height: AppSpacing.xl),
            _identity(context, profile),
            const SizedBox(height: AppSpacing.lg),
            _preferences(context, profile),
            const SizedBox(height: AppSpacing.xl),
            if (widget.onGiveRole != null) ...[
              _roleActions(context, profile),
              const SizedBox(height: AppSpacing.xl),
            ],
            Text('Daireler', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: AppSpacing.sm),
            if (profile.units.isEmpty)
              const SpGuidanceCard(icon: Icons.home_outlined, title: 'Daire kaydı yok', message: 'Bu kişi şu an hiçbir daireye bağlı değil.')
            else
              for (var i = 0; i < profile.units.length; i++)
                _TimelineEntry(
                  unit: profile.units[i],
                  last: i == profile.units.length - 1,
                  onTap: widget.onOpenUnit == null ? null : () => widget.onOpenUnit!(profile.units[i].unitId),
                ),
          ],
        ],
      ),
    );
  }

  Widget _contact(BuildContext context, PersonSummary person, PersonProfile profile) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Align(
          alignment: Alignment.centerRight,
          child: testId('person_edit_btn', TextButton.icon(
            key: const Key('person_edit_btn'),
            onPressed: () => _edit(profile),
            icon: const Icon(Icons.edit_outlined, size: 16),
            label: const Text('Kişiyi düzenle'),
          ), label: 'Kişi bilgilerini düzenle'),
        ),
        if (person.email.isNotEmpty)
          ListTile(contentPadding: EdgeInsets.zero, leading: const Icon(Icons.mail_outline), title: Text(person.email)),
        if (person.phone.isNotEmpty)
          ListTile(contentPadding: EdgeInsets.zero, leading: const Icon(Icons.phone_outlined), title: Text(person.phone)),
      ],
    );
  }

  Widget _login(BuildContext context, PersonProfile profile) {
    final login = profile.person.login;
    final canResend = login == PersonLogin.pending && profile.activationUnit != null;
    return SpGuidanceCard(
      icon: switch (login) {
        PersonLogin.active => Icons.verified_user_outlined,
        PersonLogin.pending => Icons.mark_email_unread_outlined,
        PersonLogin.none => Icons.no_accounts_outlined,
      },
      title: login.label,
      message: switch (login) {
        PersonLogin.active => 'Kişi kendi şifresiyle giriş yapabiliyor.',
        PersonLogin.pending => 'Kişi etkinleştirme bağlantısını henüz kullanmadı. Yeni bir bağlantı eskisini geçersiz kılar.',
        PersonLogin.none => 'Bu kişinin giriş hesabı yok (ör. hane üyesi).',
      },
      tone: switch (login) {
        PersonLogin.active => SpTone.success,
        PersonLogin.pending => SpTone.warning,
        PersonLogin.none => SpTone.neutral,
      },
      action: login == PersonLogin.none
          ? testId('person_open_login_btn', FilledButton.icon(
              key: const Key('person_open_login_btn'),
              onPressed: _openingLogin ? null : () => _openLogin(profile),
              icon: const Icon(Icons.login_outlined, size: 16),
              label: const Text('Giriş hesabı aç'),
            ))
          : canResend
          ? testId('person_resend_activation_btn', FilledButton.icon(
              key: const Key('person_resend_activation_btn'),
              onPressed: _resending ? null : () => _resend(profile),
              icon: const Icon(Icons.send_outlined, size: 16),
              label: const Text('Bağlantıyı yeniden gönder'),
            ))
          : null,
    );
  }
}

extension on _PersonProfilePageState {
  /// Person-first role actions: the person is fixed, the unit is chosen next.
  Widget _roleActions(BuildContext context, PersonProfile profile) {
    Widget action(String role, String label, IconData icon) => testId(
          'person_role_${role.toLowerCase()}_btn',
          OutlinedButton.icon(
            key: Key('person_role_${role.toLowerCase()}_btn'),
            onPressed: () => widget.onGiveRole!(profile.person, role),
            icon: Icon(icon, size: 16),
            label: Text(label),
          ),
          label: label,
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Bu kişiye rol ver', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: AppSpacing.xs),
        Text('Önce daireyi seçersiniz; kişi sabit kalır.', style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: AppSpacing.sm),
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.sm,
          children: [
            action('TENANT', 'Kiracı olarak yerleştir', Icons.key_outlined),
            action('OWNER', 'Kat maliki yap', Icons.home_work_outlined),
            action('MEMBER', 'Haneye ekle', Icons.group_add_outlined),
          ],
        ),
      ],
    );
  }

  Widget _identity(BuildContext context, PersonProfile profile) {
    final masked = profile.record.nationalIdMasked;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Kimlik', style: Theme.of(context).textTheme.titleMedium),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.badge_outlined),
          title: Text(masked == null ? 'T.C. kimlik numarası kayıtlı değil' : 'T.C. kimlik no: $masked'),
          subtitle: const Text('Banka ödemelerini daireyle eşleştirmede kullanılır.'),
          trailing: Wrap(
            spacing: AppSpacing.xs,
            children: [
              if (masked != null)
                testId('person_national_id_clear_btn', TextButton(
                  key: const Key('person_national_id_clear_btn'),
                  onPressed: _savingId ? null : () => _editNationalId(profile, clear: true),
                  child: const Text('Kaldır'),
                ), label: 'Kimlik numarasını kaldır'),
              testId('person_national_id_btn', OutlinedButton(
                key: const Key('person_national_id_btn'),
                onPressed: _savingId ? null : () => _editNationalId(profile),
                child: Text(masked == null ? 'Ekle' : 'Değiştir'),
              ), label: masked == null ? 'Kimlik numarası ekle' : 'Kimlik numarasını değiştir'),
            ],
          ),
        ),
      ],
    );
  }

  Widget _preferences(BuildContext context, PersonProfile profile) {
    final p = profile.record.preferences;
    final consents = profile.record.consents;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: Text('İletişim tercihleri', style: Theme.of(context).textTheme.titleMedium)),
            testId('person_preferences_btn', TextButton.icon(
              key: const Key('person_preferences_btn'),
              onPressed: () => _editPreferences(profile),
              icon: const Icon(Icons.edit_outlined, size: 16),
              label: const Text('Düzenle'),
            ), label: 'İletişim tercihlerini düzenle'),
          ],
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.forum_outlined),
          title: Text('${p.channelLabel} • ${p.languageLabel}'),
          subtitle: Text(p.emergencyName == null
              ? 'Acil durum kişisi girilmemiş'
              : 'Acil durum: ${p.emergencyName} (${p.emergencyPhone ?? ''})'),
        ),
        if (consents.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.xs),
          Semantics(
            container: true,
            label: 'İzinler, kişinin kendisi tarafından yönetilir',
            child: Wrap(
              spacing: AppSpacing.xs,
              runSpacing: AppSpacing.xs,
              children: [
                for (final c in consents)
                  SpStatusBadge(
                    label: '${c.label}: ${c.granted ? 'izin var' : 'izin yok'}',
                    tone: c.granted ? SpTone.success : SpTone.neutral,
                  ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            'İletişim izinlerini yalnızca kişinin kendisi değiştirebilir (KVKK).',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ],
    );
  }
}

/// A unit relation as one step of a vertical timeline (person module U10).
class _TimelineEntry extends StatelessWidget {
  final PersonUnit unit;
  final bool last;
  final VoidCallback? onTap;

  const _TimelineEntry({required this.unit, required this.last, this.onTap});

  String _date(DateTime? d) =>
      d == null ? '—' : '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year}';

  @override
  Widget build(BuildContext context) {
    final tone = unit.active ? SpTone.success : SpTone.neutral;
    final period = unit.active
        ? '${_date(unit.startDate)} – devam ediyor'
        : '${_date(unit.startDate)} – ${_date(unit.endDate)}';
    final entry = Semantics(
      label: '${unit.block} daire ${unit.unitNo}, ${unit.relationLabel}, $period',
      button: onTap != null,
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: 24,
              child: Column(
                children: [
                  Icon(unit.active ? Icons.circle : Icons.circle_outlined, size: 12, color: tone.foreground(context)),
                  if (!last) Expanded(child: VerticalDivider(width: 2, color: Theme.of(context).dividerColor)),
                ],
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.lg),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(child: Text('${unit.block} • Daire ${unit.unitNo}', style: Theme.of(context).textTheme.titleSmall)),
                        SpStatusBadge(label: unit.relationLabel, tone: tone),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Text(period, style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
    if (onTap == null) return entry;
    return testId(
      'person_unit_${unit.unitId}',
      InkWell(key: Key('person_unit_${unit.unitId}'), onTap: onTap, child: entry),
      label: '${unit.block} daire ${unit.unitNo} çalışma alanını aç',
    );
  }
}