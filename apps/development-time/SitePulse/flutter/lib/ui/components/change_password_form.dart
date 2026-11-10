import 'package:flutter/material.dart';

import '../../testing/test_id.dart';
import '../dashboard/dashboard_controller.dart';
import '../design_system/sp_guidance_card.dart';
import '../design_system/sp_tone.dart';
import '../theme/app_theme.dart';

/// Minimum length of a new password; mirrors the server's `MIN_PASSWORD_LENGTH`.
const int kMinPasswordLength = 10;

/// Current / new / confirm password fields with validation and a submit button.
///
/// Shared by the forced password change screen (temporary password, STORY-06-06)
/// and the voluntary change in the profile sheet. Automation ids are
/// `<idPrefix>_current`, `<idPrefix>_new`, `<idPrefix>_confirm` and [submitId].
class ChangePasswordForm extends StatefulWidget {
  final DashboardController controller;
  final String idPrefix;
  final String submitId;
  final String currentLabel;
  final String submitLabel;

  /// Called after the server accepted the new password.
  final VoidCallback? onChanged;

  const ChangePasswordForm({
    super.key,
    required this.controller,
    this.idPrefix = 'change_password',
    this.submitId = 'btn_submit_change_password',
    this.currentLabel = 'Mevcut Şifre',
    this.submitLabel = 'Şifreyi Güncelle',
    this.onChanged,
  });

  @override
  State<ChangePasswordForm> createState() => _ChangePasswordFormState();
}

class _ChangePasswordFormState extends State<ChangePasswordForm> {
  final _current = TextEditingController();
  final _new = TextEditingController();
  final _confirm = TextEditingController();
  bool _submitting = false;
  bool _obscure = true;
  String? _error;

  @override
  void dispose() {
    _current.dispose();
    _new.dispose();
    _confirm.dispose();
    super.dispose();
  }

  String? _validate() {
    final current = _current.text.trim();
    final next = _new.text.trim();
    if (current.isEmpty || next.isEmpty || _confirm.text.trim().isEmpty) {
      return 'Lütfen tüm alanları eksiksiz doldurunuz.';
    }
    if (next != _confirm.text.trim()) return 'Yeni şifreler birbiriyle uyuşmuyor.';
    if (next.length < kMinPasswordLength) return 'Yeni şifre en az $kMinPasswordLength karakter olmalıdır.';
    if (next == current) return 'Yeni şifre mevcut şifreden farklı olmalıdır.';
    return null;
  }

  Future<void> _submit() async {
    final invalid = _validate();
    if (invalid != null) {
      setState(() => _error = invalid);
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    final ok = await widget.controller.changePassword(
      email: widget.controller.userSession.email,
      currentPassword: _current.text.trim(),
      newPassword: _new.text.trim(),
    );
    if (!mounted) return;
    if (ok) {
      widget.onChanged?.call();
      // The parent may already be gone (the router leaves the forced screen).
      if (mounted) setState(() => _submitting = false);
    } else {
      setState(() {
        _submitting = false;
        _error = widget.controller.authMessage ?? 'Şifre güncellenemedi.';
      });
    }
  }

  Widget _field(String id, TextEditingController controller, String label, {required TextInputAction action}) {
    return testId(id, TextField(
      key: Key(id),
      controller: controller,
      obscureText: _obscure,
      autocorrect: false,
      enableSuggestions: false,
      textInputAction: action,
      onSubmitted: action == TextInputAction.done ? (_) => _submitting ? null : _submit() : null,
      onChanged: (_) {
        if (_error != null) setState(() => _error = null);
      },
      decoration: InputDecoration(
        labelText: label,
        filled: true,
        fillColor: AppColors.card(context),
        prefixIcon: const Icon(Icons.lock_outline, size: 18),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(AppRadius.control)),
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final error = _error;
    return AutofillGroup(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (error != null) ...[
            testId('${widget.idPrefix}_error', SpGuidanceCard(
              key: Key('${widget.idPrefix}_error'),
              icon: Icons.error_outline,
              title: 'Şifre güncellenemedi',
              message: error,
              tone: SpTone.danger,
              tonedBorder: true,
            )),
            const SizedBox(height: AppSpacing.md),
          ],
          _field('${widget.idPrefix}_current', _current, widget.currentLabel, action: TextInputAction.next),
          const SizedBox(height: AppSpacing.md),
          _field('${widget.idPrefix}_new', _new, 'Yeni Şifre (en az $kMinPasswordLength karakter)', action: TextInputAction.next),
          const SizedBox(height: AppSpacing.md),
          _field('${widget.idPrefix}_confirm', _confirm, 'Yeni Şifre Tekrar', action: TextInputAction.done),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: () => setState(() => _obscure = !_obscure),
              icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off, size: 18),
              label: Text(_obscure ? 'Şifreleri göster' : 'Şifreleri gizle'),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          testId(widget.submitId, ElevatedButton(
            key: Key(widget.submitId),
            onPressed: _submitting ? null : _submit,
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primaryFill,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.md + 2),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.control)),
            ),
            child: Text(_submitting ? 'Kaydediliyor...' : widget.submitLabel),
          )),
        ],
      ),
    );
  }
}
