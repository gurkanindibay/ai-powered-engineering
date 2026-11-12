import 'package:flutter/material.dart';

import '../../domain/errors/app_exception.dart';
import '../../l10n/app_strings.dart';

import '../theme/app_theme.dart';
import '../components/app_fullscreen_page.dart';

/// Kind of a transient message. Each kind has its own icon and fill so that an
/// error never looks like a success (status is never shown by colour alone).
enum ToastKind { success, info, warning, error }

extension ToastKindStyle on ToastKind {
  Color get fill => switch (this) {
    ToastKind.success => AppColors.successFill,
    ToastKind.info => AppColors.infoFill,
    ToastKind.warning => AppColors.warningFill,
    ToastKind.error => AppColors.dangerFill,
  };

  IconData get icon => switch (this) {
    ToastKind.success => Icons.check_circle_rounded,
    ToastKind.info => Icons.info_rounded,
    ToastKind.warning => Icons.warning_rounded,
    ToastKind.error => Icons.error_rounded,
  };

  /// Screen-reader prefix so the kind is announced, not only seen.
  String get spokenPrefix => switch (this) {
    ToastKind.success => 'Başarılı',
    ToastKind.info => 'Bilgi',
    ToastKind.warning => 'Uyarı',
    ToastKind.error => 'Hata',
  };
}

/// Builds a snackbar in the house style.
///
/// Success and info messages close after 4 seconds; warnings after 6; errors
/// stay until the user dismisses them (close icon) or acts on them.
SnackBar spSnackBar({
  required ToastKind kind,
  required Widget content,
  Duration? duration,
  SnackBarAction? action,
  SnackBarBehavior? behavior,
}) {
  final resolvedDuration =
      duration ??
      switch (kind) {
        ToastKind.success || ToastKind.info => const Duration(seconds: 4),
        ToastKind.warning => const Duration(seconds: 6),
        ToastKind.error => const Duration(days: 1),
      };
  final rawMessage = content is Text ? content.data : null;
  final message = kind == ToastKind.error && rawMessage != null
      ? AppStrings.localizeBackendMessage(rawMessage)
      : rawMessage;
  final resolvedContent = message != rawMessage && content is Text
      ? Text(message!, style: content.style)
      : content;
  return SnackBar(
    backgroundColor: kind.fill,
    duration: resolvedDuration,
    behavior: behavior,
    action: action,
    showCloseIcon:
        kind == ToastKind.error ||
        resolvedDuration > const Duration(seconds: 6),
    closeIconColor: AppColors.onFill,
    content: Semantics(
      liveRegion: true,
      label: message == null ? null : '${kind.spokenPrefix}: $message',
      child: ExcludeSemantics(
        excluding: message != null,
        child: Row(
          children: [
            Icon(kind.icon, color: AppColors.onFill, size: 20),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: DefaultTextStyle.merge(
                style: const TextStyle(
                  color: AppColors.onFill,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
                child: resolvedContent,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// Compatibility builder used where a screen still passes a colour.
///
/// The kind is taken from [backgroundColor] when it is a status colour, and
/// otherwise from the message wording, so legacy call sites get the right
/// icon and fill without each one restating its kind.
SnackBar appSnackBar({
  required Widget content,
  Color? backgroundColor,
  Duration? duration,
  SnackBarAction? action,
  SnackBarBehavior? behavior,
  ToastKind? kind,
}) {
  return spSnackBar(
    kind:
        kind ??
        inferToastKind(
          backgroundColor: backgroundColor,
          message: content is Text ? content.data : null,
        ),
    content: content,
    duration: duration,
    action: action,
    behavior: behavior,
  );
}

const _errorWords = [
  'hata',
  'başarısız',
  'geçersiz',
  'zorunlu',
  'bulunamadı',
  'yapılamadı',
  'edilemedi',
  'alınamadı',
  'reddedildi',
  'eşleşmiyor',
  'olmalı',
  'giriniz',
  'girin',
  'seçiniz',
  'lütfen',
  'error',
  'failed',
  'yetkisiz',
];
const _warningWords = ['uyarı', 'dikkat', 'çevrimdışı', 'bekl'];

/// Picks a [ToastKind] for a legacy snackbar.
ToastKind inferToastKind({Color? backgroundColor, String? message}) {
  final argb = backgroundColor?.toARGB32();
  const success = [0xFF10B981, 0xFF047857, 0xFF4CAF50, 0xFF009688];
  const error = [0xFFEF4444, 0xFFB91C1C, 0xFFDC2626, 0xFFFF5252, 0xFFF44336];
  const warning = [0xFFF59E0B, 0xFFB45309, 0xFFFF9800];
  if (argb != null) {
    if (success.contains(argb)) return ToastKind.success;
    if (error.contains(argb)) return ToastKind.error;
    if (warning.contains(argb)) return ToastKind.warning;
  }
  final text = (message ?? '').toLowerCase();
  if (_errorWords.any(text.contains)) return ToastKind.error;
  if (_warningWords.any(text.contains)) return ToastKind.warning;
  if (text.contains('başarı') ||
      text.contains('kaydedildi') ||
      text.contains('oluşturuldu') ||
      text.contains('kopyalandı') ||
      text.contains('gönderildi') ||
      text.contains('eklendi') ||
      text.contains('güncellendi') ||
      text.contains('silindi') ||
      text.contains('onaylandı')) {
    return ToastKind.success;
  }
  return ToastKind.info;
}

/// One-line helpers: `SpToast.success(context, 'Kaydedildi')`.
class SpToast {
  const SpToast._();

  static void show(
    BuildContext context,
    String message,
    ToastKind kind, {
    SnackBarAction? action,
  }) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        spSnackBar(kind: kind, content: Text(message), action: action),
      );
  }

  static void success(BuildContext context, String message) =>
      show(context, message, ToastKind.success);
  static void info(BuildContext context, String message) =>
      show(context, message, ToastKind.info);
  static void warning(BuildContext context, String message) =>
      show(context, message, ToastKind.warning);
  static void error(
    BuildContext context,
    String message, {
    SnackBarAction? action,
  }) => show(context, message, ToastKind.error, action: action);

  /// Shows an error toast from an exception or error object, translating
  /// known [AppException] error codes to user-friendly messages.
  static void exception(
    BuildContext context,
    Object error, {
    SnackBarAction? action,
  }) {
    final String message;
    if (error is AppException) {
      message = AppStrings.localizedErrorMessage(
        error.code,
        fallback: error.message,
      );
    } else {
      message = error.toString().replaceFirst(RegExp(r'^Exception:\s*'), '');
    }
    SpToast.error(context, message, action: action);
  }
}

/// Full-screen confirmation page that names the object and the consequence.
///
/// Adapter over [AppFullscreenPage.pushConfirmation], the one confirmation
/// implementation. Cancel sits left of confirm in the sticky bottom bar; a
/// destructive confirm uses the danger fill. Back counts as cancel.
Future<bool> showSpConfirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  String cancelLabel = AppStrings.cancel,
  bool destructive = false,
  String? confirmKey,
}) async {
  final result = await AppFullscreenPage.pushConfirmation(
    context: context,
    title: title,
    message: message,
    confirmLabel: confirmLabel,
    cancelLabel: cancelLabel,
    confirmColor: destructive ? AppColors.dangerFill : AppColors.primaryFill,
    icon: destructive
        ? Icons.warning_amber_rounded
        : Icons.help_outline_rounded,
    iconColor: destructive ? AppColors.accentRed : AppColors.accentCyan,
    cancelId: 'btn_confirm_cancel',
    confirmId: confirmKey ?? 'btn_confirm_ok',
  );
  return result ?? false;
}
