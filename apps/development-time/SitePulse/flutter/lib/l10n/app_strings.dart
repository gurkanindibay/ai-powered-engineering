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
}
