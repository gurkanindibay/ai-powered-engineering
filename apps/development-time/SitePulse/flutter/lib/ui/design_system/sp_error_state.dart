import 'package:flutter/material.dart';

import '../../domain/errors/app_exception.dart';
import '../../l10n/app_strings.dart';
import '../theme/app_theme.dart';

/// Standard full-content or card error state with diagnostic details and retry action.
class SpErrorState extends StatelessWidget {
  final Object? error;
  final String? title;
  final String? message;
  final VoidCallback? onRetry;
  final String retryLabel;
  final IconData icon;

  const SpErrorState({
    super.key,
    this.error,
    this.title,
    this.message,
    this.onRetry,
    this.retryLabel = 'Tekrar Dene',
    this.icon = Icons.error_outline_rounded,
  });

  @override
  Widget build(BuildContext context) {
    final resolvedTitle = title ?? _resolveTitle();
    final resolvedMessage = message ?? _resolveMessage();

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(AppSpacing.lg),
              decoration: BoxDecoration(
                color: AppColors.dangerFill.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 44, color: AppColors.accentRed),
            ),
            const SizedBox(height: AppSpacing.lg),
            Text(
              resolvedTitle,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: AppColors.textPrimary(context),
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              resolvedMessage,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                color: AppColors.textSecondary(context),
                height: 1.4,
              ),
            ),
            if (onRetry != null) ...[
              const SizedBox(height: AppSpacing.xl),
              ElevatedButton.icon(
                onPressed: onRetry,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primaryFill,
                  foregroundColor: AppColors.onFill,
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.xl,
                    vertical: AppSpacing.md,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppRadius.control),
                  ),
                ),
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: Text(retryLabel),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _resolveTitle() {
    if (error is NetworkException) return 'Bağlantı Hatası';
    if (error is RequestTimeoutException) return 'Zaman Aşımı';
    if (error is ApiException) {
      final apiErr = error as ApiException;
      if (apiErr.isPermissionDenied) return 'Erişim Engellendi';
      if (apiErr.isNotFound) return 'Kayıt Bulunamadı';
      if (apiErr.isConflict) return 'İşlem Çakışması';
    }
    return 'Bir Sorun Oluştu';
  }

  String _resolveMessage() {
    if (error is AppException) {
      final appErr = error as AppException;
      return AppStrings.localizedErrorMessage(
        appErr.code,
        fallback: appErr.message,
      );
    }
    if (error != null) {
      return error.toString().replaceFirst(RegExp(r'^Exception:\s*'), '');
    }
    return 'Beklenmeyen bir hata oluştu. Lütfen tekrar deneyiniz.';
  }
}
