/// What a site manager is told after creating a login account (SPEC person module, S2/S3).
///
/// The manager never sees a password: the person receives a single-use link at
/// their own address. These messages describe that link's delivery state.
String activationStatusMessage(String? status, String email) {
  switch (status) {
    case 'SENT':
      return '$email adresine hesap etkinleştirme bağlantısı gönderildi. '
          'Kişi şifresini bu bağlantıyla kendisi belirleyecek (72 saat geçerli).';
    case 'DELIVERY_FAILED':
      return 'Etkinleştirme bağlantısı $email adresine gönderilemedi. '
          'Sakin kartındaki "Bağlantıyı yeniden gönder" ile tekrar deneyin.';
    case 'NO_EMAIL':
      return 'E-posta adresi olmadığı için giriş hesabı etkinleştirilemiyor. '
          'Bir e-posta adresi ekleyip bağlantıyı gönderin.';
    default:
      return 'Hesap oluşturuldu. Etkinleştirme durumu sakin kartında görünür.';
  }
}
