import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../domain/models/dues_models.dart';
import '../theme/app_theme.dart';

import 'app_fullscreen_page.dart';

enum CheckoutPaymentMethod {
  card,
  virtualIban,
}

class PaymentCheckoutDialog extends StatefulWidget {
  final AidatBorcu dues;
  final String siteName;
  final String unitDesc;
  final String virtualIban;
  final CheckoutPaymentMethod initialMethod;
  final VoidCallback onPaymentSuccess;

  const PaymentCheckoutDialog({
    super.key,
    required this.dues,
    required this.siteName,
    required this.unitDesc,
    this.virtualIban = 'TR12 0006 2000 0000 0000 0014',
    this.initialMethod = CheckoutPaymentMethod.card,
    required this.onPaymentSuccess,
  });

  @override
  State<PaymentCheckoutDialog> createState() => _PaymentCheckoutDialogState();
}

class _PaymentCheckoutDialogState extends State<PaymentCheckoutDialog> {
  late CheckoutPaymentMethod _selectedMethod;
  final _cardNumberCtrl = TextEditingController(text: '5428 •••• •••• 9012');
  final _cardHolderCtrl = TextEditingController(text: 'Ahmet Yılmaz');
  final _expiryCtrl = TextEditingController(text: '12/28');
  final _cvvCtrl = TextEditingController(text: '884');

  @override
  void initState() {
    super.initState();
    _selectedMethod = widget.initialMethod;
  }

  @override
  void dispose() {
    _cardNumberCtrl.dispose();
    _cardHolderCtrl.dispose();
    _expiryCtrl.dispose();
    _cvvCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isOverdue = widget.dues.gecikmeTazminati > Decimal.zero;

    return AppFullscreenPage(
      title: 'Aidat Ödeme Adımı',
      subtitle: '${widget.siteName} • ${widget.unitDesc}',
      leading: IconButton(
        icon: Icon(
          Icons.arrow_back_ios_new_rounded,
          color: AppColors.textPrimary(context),
          size: 20,
        ),
        tooltip: 'Geri Dön',
        onPressed: () => Navigator.pop(context),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [

              // Debt Breakdown Card
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: AppColors.card(context),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: AppColors.border(context)),
                ),
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Text(
                            '${widget.dues.donem} Aidat Ana Parası',
                            style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '₺${widget.dues.anaPara.toStringAsFixed(2)}',
                          style: TextStyle(color: AppColors.textPrimary(context), fontSize: 12, fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                    if (isOverdue) ...[
                      const SizedBox(height: 6),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Expanded(
                            child: Row(
                              children: [
                                const Text('KMK %5 Kanuni Gecikme', style: TextStyle(color: AppColors.accentRed, fontSize: 11)),
                                const SizedBox(width: 4),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                                  decoration: BoxDecoration(
                                    color: AppColors.accentRed.withValues(alpha: 0.15),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(
                                    '${widget.dues.gecikenGunSayisi} gün',
                                    style: const TextStyle(color: AppColors.accentRed, fontSize: 10, fontWeight: FontWeight.bold),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            '+₺${widget.dues.gecikmeTazminati.toStringAsFixed(2)}',
                            style: const TextStyle(color: AppColors.accentRed, fontSize: 11, fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                    ],
                    Divider(color: AppColors.border(context), height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Text(
                            'Ödenecek Toplam Tutar',
                            style: TextStyle(color: AppColors.textPrimary(context), fontWeight: FontWeight.bold, fontSize: 13),
                          ),
                        ),
                        Text(
                          '₺${widget.dues.toplamTutar.toStringAsFixed(2)}',
                          style: const TextStyle(color: AppColors.accentCyan, fontWeight: FontWeight.bold, fontSize: 17),
                        ),
                      ],
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 18),

              // Payment Method Title
              Text(
                'Ödeme Yöntemini Seçin',
                style: TextStyle(
                  color: AppColors.textPrimary(context),
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),

              // Segmented Method Selector
              Row(
                children: [
                  Expanded(
                    child: _buildMethodSelectorOption(
                      method: CheckoutPaymentMethod.card,
                      icon: Icons.credit_card,
                      title: 'Kredi Kartı',
                      subtitle: '3D Secure',
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _buildMethodSelectorOption(
                      method: CheckoutPaymentMethod.virtualIban,
                      icon: Icons.account_balance,
                      title: 'Sanal IBAN',
                      subtitle: 'FAST / Havale',
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 16),

              // Content based on selected method
              if (_selectedMethod == CheckoutPaymentMethod.card)
                _buildCardPaymentView()
              else
                _buildVirtualIbanPaymentView(),
            ],
          ),
    );
  }

  Widget _buildMethodSelectorOption({
    required CheckoutPaymentMethod method,
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
    final isSelected = _selectedMethod == method;
    return InkWell(
      onTap: () {
        setState(() {
          _selectedMethod = method;
        });
      },
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        decoration: BoxDecoration(
          color: isSelected ? AppColors.accentCyan.withValues(alpha: 0.12) : AppColors.card(context),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected ? AppColors.accentCyan : AppColors.border(context),
            width: isSelected ? 1.5 : 1,
          ),
        ),
        child: Row(
          children: [
            Icon(
              icon,
              size: 20,
              color: isSelected ? AppColors.accentCyan : AppColors.textSecondary(context),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: isSelected ? AppColors.accentCyan : AppColors.textPrimary(context),
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    subtitle,
                    style: TextStyle(color: AppColors.textSecondary(context), fontSize: 10),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCardPaymentView() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _cardHolderCtrl,
          style: TextStyle(color: AppColors.textPrimary(context), fontSize: 13),
          decoration: InputDecoration(
            labelText: 'Kart Üzerindeki İsim',
            labelStyle: TextStyle(color: AppColors.textSecondary(context), fontSize: 12),
            filled: true,
            fillColor: AppColors.card(context),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          ),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _cardNumberCtrl,
          style: TextStyle(color: AppColors.textPrimary(context), fontSize: 13),
          decoration: InputDecoration(
            labelText: 'Kart Numarası',
            labelStyle: TextStyle(color: AppColors.textSecondary(context), fontSize: 12),
            prefixIcon: const Icon(Icons.credit_card, size: 18),
            filled: true,
            fillColor: AppColors.card(context),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _expiryCtrl,
                style: TextStyle(color: AppColors.textPrimary(context), fontSize: 13),
                decoration: InputDecoration(
                  labelText: 'SKT (AA/YY)',
                  labelStyle: TextStyle(color: AppColors.textSecondary(context), fontSize: 12),
                  filled: true,
                  fillColor: AppColors.card(context),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: TextField(
                controller: _cvvCtrl,
                obscureText: true,
                style: TextStyle(color: AppColors.textPrimary(context), fontSize: 13),
                decoration: InputDecoration(
                  labelText: 'CVV / CVC',
                  labelStyle: TextStyle(color: AppColors.textSecondary(context), fontSize: 12),
                  filled: true,
                  fillColor: AppColors.card(context),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            const Icon(Icons.verified_user_outlined, size: 14, color: AppColors.accentGreen),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                '256-Bit SSL & 3D Secure banka güvencesiyle korunur',
                style: TextStyle(color: AppColors.textSecondary(context), fontSize: 11),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: () {
              Navigator.pop(context);
              widget.onPaymentSuccess();
            },
            icon: const Icon(Icons.lock, size: 16),
            label: Text(
              '3D Secure ile ₺${widget.dues.toplamTutar.toStringAsFixed(2)} Öde',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.accentCyan,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 13),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildVirtualIbanPaymentView() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppColors.card(context),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppColors.border(context)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Text(
                      'Dairenize Tanımlı Sanal IBAN',
                      style: TextStyle(color: AppColors.textSecondary(context), fontSize: 11, fontWeight: FontWeight.w600),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: AppColors.accentGreen.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Text(
                      'Otomatik Eşleşir',
                      style: TextStyle(color: AppColors.accentGreen, fontSize: 10, fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: AppColors.background(context),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppColors.border(context)),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Text(
                        widget.virtualIban,
                        style: TextStyle(
                          fontFamily: 'monospace',
                          color: AppColors.textPrimary(context),
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 0.6,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 4),
                    InkWell(
                      onTap: () {
                        Clipboard.setData(ClipboardData(text: widget.virtualIban.replaceAll(' ', '')));
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Sanal IBAN panoya kopyalandı!'),
                            duration: Duration(seconds: 2),
                            backgroundColor: AppColors.accentGreen,
                          ),
                        );
                      },
                      borderRadius: BorderRadius.circular(6),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                        decoration: BoxDecoration(
                          color: AppColors.accentCyan.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.copy, size: 12, color: AppColors.accentCyan),
                            SizedBox(width: 4),
                            Text(
                              'Kopyala',
                              style: TextStyle(color: AppColors.accentCyan, fontSize: 11, fontWeight: FontWeight.bold),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('Alıcı Adı:', style: TextStyle(color: AppColors.textSecondary(context), fontSize: 11)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${widget.siteName} Yönetimi',
                      textAlign: TextAlign.end,
                      style: TextStyle(color: AppColors.textPrimary(context), fontSize: 11, fontWeight: FontWeight.bold),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('Banka:', style: TextStyle(color: AppColors.textSecondary(context), fontSize: 11)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'VakıfBank Kurumsal Havuz',
                      textAlign: TextAlign.end,
                      style: TextStyle(color: AppColors.textPrimary(context), fontSize: 11, fontWeight: FontWeight.bold),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('Ödenecek Tutar:', style: TextStyle(color: AppColors.textSecondary(context), fontSize: 11)),
                  Text('₺${widget.dues.toplamTutar.toStringAsFixed(2)}', style: const TextStyle(color: AppColors.accentCyan, fontSize: 12, fontWeight: FontWeight.bold)),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: AppColors.accentCyan.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppColors.accentCyan.withValues(alpha: 0.2)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.info_outline, size: 16, color: AppColors.accentCyan),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Açıklama alanına hiçbir şey yazmanıza gerek yoktur. Bu IBAN sadece dairenize özeldir ve gönderdiğiniz tutar FAST ile saniyeler içinde aidat borcunuzu kapatır.',
                  style: TextStyle(color: AppColors.textPrimary(context), fontSize: 11, height: 1.35),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('FAST transferiniz ulaştığında sistem borcunuzu otomatik kapatacak ve bildirim gönderecektir.'),
                  backgroundColor: AppColors.accentGreen,
                  duration: Duration(seconds: 4),
                ),
              );
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.accentCyan,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            child: const Text('Anladım, Kapat', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
          ),
        ),
      ],
    );
  }
}
