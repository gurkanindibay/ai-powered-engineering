import 'dart:convert';

import 'package:flutter/material.dart';

import '../../domain/services/api_client.dart';
import '../../testing/test_id.dart';
import '../design_system/sp_guidance_card.dart';
import '../design_system/sp_tone.dart';
import '../theme/app_theme.dart';
import 'app_fullscreen_page.dart';

/// Asks the signed-in user to re-enter their password before a sensitive action
/// (the server answers `STEP_UP_REQUIRED`). Returns `true` once the server has
/// verified it; the verification then covers sensitive actions for a few minutes.
///
/// Shared: use it for any action guarded by step-up (login email change,
/// ownership transfer, payment reversal) instead of a screen-local password form.
Future<bool> showStepUpPrompt(BuildContext context, {required String reason}) async {
  final verified = await AppFullscreenPage.push<bool>(
    context: context,
    builder: (_) => StepUpPromptPage(reason: reason),
  );
  return verified ?? false;
}

class StepUpPromptPage extends StatefulWidget {
  final String reason;

  const StepUpPromptPage({super.key, required this.reason});

  @override
  State<StepUpPromptPage> createState() => _StepUpPromptPageState();
}

class _StepUpPromptPageState extends State<StepUpPromptPage> {
  final _password = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _verify() async {
    if (_password.text.isEmpty) {
      setState(() => _error = 'Şifrenizi girin.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final password = _password.text;
    _password.clear();
    try {
      final response = await ApiClient.post(
        ApiClient.uri('/api/v1/auth/step-up'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'password': password}),
      ).timeout(const Duration(seconds: 15));
      if (!mounted) return;
      if (response.statusCode == 200) {
        Navigator.pop(context, true);
        return;
      }
      setState(() => _error = 'Şifre doğrulanamadı. Kontrol edip tekrar deneyin.');
    } catch (_) {
      if (mounted) setState(() => _error = 'Sunucuya ulaşılamadı. Tekrar deneyin.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppFullscreenPage(
      title: 'Şifrenizi doğrulayın',
      bottomBar: AppFullscreenPage.buildBottomBar(
        context: context,
        children: [
          testId('btn_step_up_verify', FilledButton(
            key: const Key('btn_step_up_verify'),
            onPressed: _busy ? null : _verify,
            child: _busy
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Doğrula ve devam et'),
          )),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SpGuidanceCard(
            icon: Icons.verified_user_outlined,
            title: 'Güvenli işlem',
            message: widget.reason,
          ),
          const SizedBox(height: AppSpacing.xl),
          testId('step_up_password', TextField(
            key: const Key('step_up_password'),
            controller: _password,
            obscureText: true,
            autofocus: true,
            enableSuggestions: false,
            autocorrect: false,
            autofillHints: const [AutofillHints.password],
            enabled: !_busy,
            onSubmitted: (_) => _busy ? null : _verify(),
            decoration: const InputDecoration(labelText: 'Şifreniz'),
          )),
          if (_error != null) ...[
            const SizedBox(height: AppSpacing.md),
            Text(_error!, style: TextStyle(color: SpTone.danger.foreground(context))),
          ],
        ],
      ),
    );
  }
}
