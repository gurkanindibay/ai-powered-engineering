/// Shared UI strings, Turkish (the default and today the only locale).
///
/// Repeated words live here once so a wording change is one edit and a second
/// locale can be added by moving this class to ARB files
/// (`flutter gen-l10n`) without touching every screen. Screen-specific copy
/// still lives with its screen.
class AppStrings {
  const AppStrings._();

  static const cancel = 'Vazgeç';
  static const close = 'Kapat';
  static const save = 'Kaydet';
  static const delete = 'Sil';
  static const ok = 'Tamam';
  static const back = 'Geri Dön';
  static const copy = 'Kopyala';
  static const logout = 'Çıkış Yap';
  static const loading = 'Yükleniyor';
  static const offlineBanner = 'Çevrimdışısınız';

  // Shared metric and resident-summary labels (used by several screens).
  static const totalUnits = 'Toplam Daire';
  static const remainingDebt = 'Kalan Borç';
  static const tenantOccupied = 'Kiracılı';
  static const ownerOccupied = 'Malik Mukim';
  static const vacantUnit = 'Boş Daire';
  static const householdResidents = 'Hane Sakini';
  static const residentSummaryTitle = 'Sakin & Mülkiyet Durum Özeti';
  static const noManagedSiteTitle = 'Yönetilen Site Bulunmuyor';

  /// Returns a user-friendly Turkish message for standard backend error codes.
  static String localizedErrorMessage(String? code, {String? fallback}) {
    if (code == 'EMAIL_ALREADY_EXISTS' || code == 'EMAIL_NOT_AVAILABLE') {
      return 'Bu e-posta adresi başka bir hesapta kullanılıyor.';
    }
    if (fallback != null) {
      final localized = localizeBackendMessage(fallback);
      if (localized != fallback) return localized;
    }
    if (code == null || code.isEmpty) {
      return fallback ?? 'Bir hata oluştu.';
    }
    return switch (code) {
      'VALIDATION_FAILED' ||
      'INVALID_REQUEST' => 'Girilen bilgiler geçersiz veya eksik.',
      'AUTHENTICATION_REQUIRED' =>
        'Oturum açmanız gerekiyor. Lütfen tekrar giriş yapın.',
      'PERMISSION_DENIED' => 'Bu işlem için yetkiniz bulunmuyor.',
      'RESOURCE_NOT_FOUND' ||
      'NOT_FOUND' => 'İstenen kayıt veya kaynak bulunamadı.',
      'CONFLICT' => 'Bu işlem mevcut kayıtla veya durumla çakışıyor.',
      'BUSINESS_RULE_VIOLATION' =>
        'İşlem bina yönetim kurallarına uygun değil.',
      'STEP_UP_REQUIRED' =>
        'Güvenli işlem için şifrenizi yeniden doğrulamanız gerekiyor.',
      'PASSWORD_CHANGE_REQUIRED' =>
        'Devam etmek için şifrenizi değiştirmeniz gerekiyor.',
      'RATE_LIMITED' =>
        'Çok fazla deneme yapıldı. Lütfen biraz bekleyip tekrar deneyin.',
      'SERVICE_UNAVAILABLE' || 'SECURITY_UNAVAILABLE' => 'Hizmet geçici olarak kullanılamıyor. Lütfen daha sonra tekrar deneyin.',
      'INTERNAL_SERVER_ERROR' || 'DATABASE_ERROR' =>
        'Sunucuda bir hata meydana geldi. Sistem yöneticisine bildirildi.',
      'NETWORK_ERROR' =>
        'İnternet bağlantısı kurulamadı. Lütfen bağlantınızı kontrol edin.',
      'TIMEOUT' => 'İşlem zaman aşımına uğradı. Lütfen tekrar deneyin.',
      _ => fallback ?? 'İşlem gerçekleştirilemedi ($code).',
    };
  }

  /// Localizes known English database and service messages before they reach the UI.
  static String localizeBackendMessage(String message) {
    final normalized = message.toLowerCase();
    if (normalized.contains(
          'an account with this email address already exists',
        ) ||
        normalized.contains(
          'this email address cannot be used for a new account',
        ) ||
        normalized.contains('email_already_exists') ||
        normalized.contains('email_not_available') ||
        normalized.contains('uq_users_active_email_lower') ||
        normalized.contains('uq_users_email_lower') ||
        normalized.contains('users_email_key') ||
        normalized.contains('uq_persons_site_email')) {
      return 'Bu e-posta adresi başka bir hesapta kullanılıyor.';
    }
    if (normalized.contains('uq_persons_site_national_id_hash')) {
      return 'Bu kimlik numarası başka bir kişi kaydında kullanılıyor.';
    }
    return message;
  }
}
