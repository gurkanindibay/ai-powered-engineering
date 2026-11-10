import 'package:flutter/material.dart';

import '../../domain/services/api_client.dart';
import '../../domain/services/person_directory_api.dart';
import '../../testing/test_id.dart';
import '../components/app_fullscreen_page.dart';
import '../design_system/sp_feedback.dart';
import '../design_system/sp_guidance_card.dart';
import '../design_system/sp_status_badge.dart';
import '../design_system/sp_tone.dart';
import '../theme/app_theme.dart';
import 'activation_status.dart';

/// One person: contact, login state and every unit they own, rent or live in, as a
/// timeline (person module U3/U4/U10).
class PersonProfilePage extends StatefulWidget {
  final int personId;
  final PersonDirectoryApi api;

  const PersonProfilePage({super.key, required this.personId, this.api = const PersonDirectoryApi()});

  @override
  State<PersonProfilePage> createState() => _PersonProfilePageState();
}

class _PersonProfilePageState extends State<PersonProfilePage> {
  PersonProfile? _profile;
  String? _error;
  bool _resending = false;

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
            const Padding(padding: EdgeInsets.all(AppSpacing.xl), child: Center(child: CircularProgressIndicator()))
          else ...[
            _contact(context, profile.person),
            const SizedBox(height: AppSpacing.lg),
            _login(context, profile),
            const SizedBox(height: AppSpacing.xl),
            Text('Daireler', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: AppSpacing.sm),
            if (profile.units.isEmpty)
              const SpGuidanceCard(icon: Icons.home_outlined, title: 'Daire kaydı yok', message: 'Bu kişi şu an hiçbir daireye bağlı değil.')
            else
              for (var i = 0; i < profile.units.length; i++)
                _TimelineEntry(unit: profile.units[i], last: i == profile.units.length - 1),
          ],
        ],
      ),
    );
  }

  Widget _contact(BuildContext context, PersonSummary person) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
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
      action: canResend
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

/// A unit relation as one step of a vertical timeline (person module U10).
class _TimelineEntry extends StatelessWidget {
  final PersonUnit unit;
  final bool last;

  const _TimelineEntry({required this.unit, required this.last});

  String _date(DateTime? d) =>
      d == null ? '—' : '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year}';

  @override
  Widget build(BuildContext context) {
    final tone = unit.active ? SpTone.success : SpTone.neutral;
    final period = unit.active
        ? '${_date(unit.startDate)} – devam ediyor'
        : '${_date(unit.startDate)} – ${_date(unit.endDate)}';
    return Semantics(
      label: '${unit.block} daire ${unit.unitNo}, ${unit.relationLabel}, $period',
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
  }
}
