import 'package:flutter/material.dart';

import '../../testing/test_id.dart';
import '../components/change_password_form.dart';
import '../dashboard/dashboard_controller.dart';
import '../design_system/sp_feedback.dart';
import '../design_system/sp_guidance_card.dart';
import '../design_system/sp_tone.dart';
import '../theme/app_theme.dart';

/// The only page a user with a temporary password can open (STORY-06-06).
///
/// Shown by the router instead of the dashboard for every role while
/// `must_change_password` is set: no navigation, no role data, no business
/// calls. The user either sets a permanent password or signs out. Once the
/// server accepts the new password the controller clears the flag and the
/// router opens the role's home page.
class ForcePasswordChangeScreen extends StatelessWidget {
  final DashboardController controller;

  const ForcePasswordChangeScreen({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    final session = controller.userSession;
    return testId('screen_force_password_change', Scaffold(
      key: const Key('screen_force_password_change'),
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: const Text('Şifre Belirleme'),
        actions: [
          testId('btn_force_password_logout', TextButton.icon(
            key: const Key('btn_force_password_logout'),
            onPressed: controller.logout,
            icon: const Icon(Icons.logout, size: 18),
            label: const Text('Çıkış Yap'),
          )),
          const SizedBox(width: AppSpacing.sm),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppSpacing.screenGutter),
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SpGuidanceCard(
                    icon: Icons.lock_reset,
                    title: 'Yeni şifrenizi belirleyin',
                    message: 'Geçici bir şifreyle giriş yaptınız. Hesap güvenliğiniz için devam etmeden önce '
                        'kalıcı bir şifre belirlemeniz gerekiyor.',
                    tone: SpTone.warning,
                    prominent: true,
                    tonedBorder: true,
                    tip: '${session.fullName} · ${session.email} · ${session.role.displayName}',
                  ),
                  const SizedBox(height: AppSpacing.xl),
                  ChangePasswordForm(
                    controller: controller,
                    currentLabel: 'Geçici Şifre',
                    submitLabel: 'Şifreyi Belirle ve Devam Et',
                    onChanged: () => SpToast.success(context, 'Şifreniz belirlendi. Hoş geldiniz.'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ));
  }
}
