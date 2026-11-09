import 'dart:convert';

import 'package:flutter/material.dart';

import '../../domain/services/api_client.dart';
import '../../testing/test_id.dart';
import '../design_system/sp_guidance_card.dart';
import '../design_system/sp_tone.dart';
import '../theme/app_theme.dart';

/// What a single-use account link does.
enum AccountLinkKind {
  /// `#/activate?token=…`: the person sets the first password of an account a manager created.
  activate,

  /// `#/confirm-email?token=…`: the new address confirms a login email change.
  confirmEmail,
}

/// The page a person reaches from the link in their email (person module S2, S3, S5).
///
/// A site manager never sees or chooses a resident's password; this page is the
/// only place it is set. Every outcome is stated plainly, and an unusable link
/// says what to do next.
class AccountLinkScreen extends StatefulWidget {
  final AccountLinkKind kind;
  final String token;

  /// Returns to the sign-in page.
  final VoidCallback onDone;

  const AccountLinkScreen({super.key, required this.kind, required this.token, required this.onDone});

  @override
  State<AccountLinkScreen> createState() => _AccountLinkScreenState();
}

enum _Stage { form, working, done, failed }

class _AccountLinkScreenState extends State<AccountLinkScreen> {
  /// Matches the server's `MIN_PASSWORD_LENGTH`.
  static const minPasswordLength = 10;

  final _formKey = GlobalKey<FormState>();
  final _password = TextEditingController();
  final _repeat = TextEditingController();
  bool _obscure = true;
  _Stage _stage = _Stage.form;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (widget.token.trim().isEmpty) {
      _stage = _Stage.failed;
      _error = 'Bağlantı eksik. E-postadaki bağlantıyı tamamen açın.';
    } else if (widget.kind == AccountLinkKind.confirmEmail) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _submit());
    }
  }

  @override
  void dispose() {
    _password.dispose();
    _repeat.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (widget.kind == AccountLinkKind.activate && !(_formKey.currentState?.validate() ?? false)) return;
    setState(() {
      _stage = _Stage.working;
      _error = null;
    });
    final path = widget.kind == AccountLinkKind.activate ? '/api/v1/auth/activate' : '/api/v1/auth/confirm-email';
    final body = widget.kind == AccountLinkKind.activate
        ? {'token': widget.token, 'new_password': _password.text}
        : {'token': widget.token};
    try {
      final response = await ApiClient.post(
        ApiClient.uri(path),
        headers: {'Content-Type': 'application/json'},
        body: json.encode(body),
      ).timeout(const Duration(seconds: 15));
      ApiClient.decode(response);
      if (mounted) setState(() => _stage = _Stage.done);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        // The form stays usable for a password-policy refusal; any token problem ends the flow.
        final tokenProblem = e.message.contains('invalid or has expired');
        _stage = tokenProblem || widget.kind == AccountLinkKind.confirmEmail ? _Stage.failed : _Stage.form;
        _error = tokenProblem
            ? 'Bu bağlantı geçersiz veya süresi dolmuş. Site yöneticinizden yeni bir bağlantı isteyin.'
            : e.message;
      });
    } catch (e) {
      AppLogger.warn('Account link request did not reach the server', tag: 'AccountLink', error: e);
      if (!mounted) return;
      setState(() {
        _stage = widget.kind == AccountLinkKind.confirmEmail ? _Stage.failed : _Stage.form;
        _error = 'Sunucuya ulaşılamadı. Bağlantınızı kontrol edip tekrar deneyin.';
      });
    }
  }

  String? _validatePassword(String? value) {
    final text = value ?? '';
    if (text.length < minPasswordLength) return 'Şifre en az $minPasswordLength karakter olmalı.';
    return null;
  }

  String? _validateRepeat(String? value) => value == _password.text ? null : 'Şifreler aynı değil.';

  @override
  Widget build(BuildContext context) {
    final activate = widget.kind == AccountLinkKind.activate;
    return Scaffold(
      appBar: AppBar(title: Text(activate ? 'Hesabınızı etkinleştirin' : 'E-posta değişikliği')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: ListView(
              padding: const EdgeInsets.all(AppSpacing.xl),
              children: [
                ..._content(context, activate),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _content(BuildContext context, bool activate) {
    switch (_stage) {
      case _Stage.done:
        return [
          testId('account_link_done', SpGuidanceCard(
            icon: Icons.verified_outlined,
            title: activate ? 'Hesabınız hazır' : 'E-posta adresiniz güncellendi',
            message: activate
                ? 'Şifreniz kaydedildi. E-posta adresiniz ve yeni şifrenizle giriş yapabilirsiniz.'
                : 'Bundan sonra yeni e-posta adresinizle giriş yapın. Açık oturumlarınız kapatıldı.',
            tone: SpTone.success,
            prominent: true,
          )),
          const SizedBox(height: AppSpacing.lg),
          testId('account_link_to_login', FilledButton(onPressed: widget.onDone, child: const Text('Giriş ekranına git'))),
        ];
      case _Stage.failed:
        return [
          testId('account_link_failed', SpGuidanceCard(
            icon: Icons.link_off,
            title: 'Bağlantı kullanılamıyor',
            message: _error ?? 'Bu bağlantı kullanılamıyor.',
            tone: SpTone.warning,
            prominent: true,
          )),
          const SizedBox(height: AppSpacing.lg),
          OutlinedButton(onPressed: widget.onDone, child: const Text('Giriş ekranına git')),
        ];
      case _Stage.working:
        if (!activate) {
          return const [
            Center(child: Padding(padding: EdgeInsets.all(AppSpacing.xl), child: CircularProgressIndicator())),
            Text('E-posta değişikliği onaylanıyor…', textAlign: TextAlign.center),
          ];
        }
        return _form(context, busy: true);
      case _Stage.form:
        return _form(context, busy: false);
    }
  }

  List<Widget> _form(BuildContext context, {required bool busy}) {
    return [
      const SpGuidanceCard(
        icon: Icons.lock_outline,
        title: 'Şifrenizi belirleyin',
        message: 'Site yöneticiniz sizin için bir hesap oluşturdu. Şifreyi yalnızca siz belirlersiniz; '
            'bağlantı bir kez kullanılabilir.',
      ),
      const SizedBox(height: AppSpacing.xl),
      Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            testId('account_link_password', TextFormField(
              key: const Key('account_link_password'),
              controller: _password,
              obscureText: _obscure,
              autofillHints: const [AutofillHints.newPassword],
              enabled: !busy,
              validator: _validatePassword,
              decoration: InputDecoration(
                labelText: 'Yeni şifre',
                helperText: 'En az $minPasswordLength karakter',
                suffixIcon: IconButton(
                  tooltip: _obscure ? 'Şifreyi göster' : 'Şifreyi gizle',
                  icon: Icon(_obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
              ),
            )),
            const SizedBox(height: AppSpacing.md),
            testId('account_link_password_repeat', TextFormField(
              key: const Key('account_link_password_repeat'),
              controller: _repeat,
              obscureText: _obscure,
              autofillHints: const [AutofillHints.newPassword],
              enabled: !busy,
              validator: _validateRepeat,
              decoration: const InputDecoration(labelText: 'Yeni şifre (tekrar)'),
              onFieldSubmitted: (_) => busy ? null : _submit(),
            )),
            if (_error != null) ...[
              const SizedBox(height: AppSpacing.md),
              Text(_error!, style: TextStyle(color: SpTone.danger.foreground(context))),
            ],
            const SizedBox(height: AppSpacing.xl),
            testId('account_link_submit', FilledButton(
              key: const Key('account_link_submit'),
              onPressed: busy ? null : _submit,
              child: busy
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Şifremi kaydet'),
            )),
          ],
        ),
      ),
    ];
  }
}
