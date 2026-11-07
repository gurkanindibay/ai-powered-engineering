import '../../testing/test_id.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import '../../l10n/app_strings.dart';
import 'package:flutter/services.dart';
import '../../domain/models/dues_models.dart';
import '../theme/app_theme.dart';

import 'app_fullscreen_page.dart';

import '../design_system/money_formatter.dart';
import '../design_system/sp_feedback.dart';
enum CheckoutPaymentMethod {
  card,
  virtualIban,
}

class PaymentCheckoutDialog extends StatefulWidget {
  final DuesLiability dues;
  final String siteName;
  final String unitDesc;
  final String virtualIban;
  final CheckoutPaymentMethod initialMethod;
  final bool isTest;
  final void Function(Decimal amount) onPaymentSuccess;

  const PaymentCheckoutDialog({
    super.key,
    required this.dues,
    required this.siteName,
    required this.unitDesc,
    this.virtualIban = '',
    this.initialMethod = CheckoutPaymentMethod.card,
    this.isTest = false,
    required this.onPaymentSuccess,
  });

  @override
  State<PaymentCheckoutDialog> createState() => _PaymentCheckoutDialogState();
}

class _PaymentCheckoutDialogState extends State<PaymentCheckoutDialog> {
  late CheckoutPaymentMethod _selectedMethod;
  late final TextEditingController _amountCtrl;
  Decimal _enteredAmount = Decimal.zero;
  late final TextEditingController _cardNumberCtrl;
  late final TextEditingController _cardHolderCtrl;
  late final TextEditingController _expiryCtrl;
  late final TextEditingController _cvvCtrl;

  @override
  void initState() {
    super.initState();
    _selectedMethod = widget.initialMethod;
    final initialVal = widget.dues.totalAmount > Decimal.zero
        ? widget.dues.totalAmount
        : Decimal.parse('500.00');
    _enteredAmount = initialVal;
    _amountCtrl = TextEditingController(text: initialVal.toStringAsFixed(2));
    _amountCtrl.addListener(_onAmountChanged);

    final isTest = widget.isTest;
    _cardNumberCtrl = TextEditingController(text: isTest ? '5428 •••• •••• 9012' : '');
    _cardHolderCtrl = TextEditingController(text: isTest ? 'Ahmet Yılmaz' : '');
    _expiryCtrl = TextEditingController(text: isTest ? '12/28' : '');
    _cvvCtrl = TextEditingController(text: isTest ? '884' : '');
  }

  void _onAmountChanged() {
    final clean = _amountCtrl.text.replaceAll(',', '.').replaceAll('₺', '').trim();
    final parsed = Decimal.tryParse(clean) ?? Decimal.zero;
    if (parsed != _enteredAmount) {
      setState(() {
        _enteredAmount = parsed;
      });
    }
  }

  @override
  void dispose() {
    _amountCtrl.removeListener(_onAmountChanged);
    _amountCtrl.dispose();
    _cardNumberCtrl.dispose();
    _cardHolderCtrl.dispose();
    _expiryCtrl.dispose();
    _cvvCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isOverdue = widget.dues.delayPenalty > Decimal.zero;

    return AppFullscreenPage(
      title: 'Aidat Ödeme Adımı',
      subtitle: '${widget.siteName} • ${widget.unitDesc}',
      leading: IconButton(
        icon: Icon(
          Icons.arrow_back_ios_new_rounded,
          color: AppColors.textPrimary(context),
          size: 20,
        ),
        tooltip: AppStrings.back,
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
                            '${widget.dues.period} Aidat Ana Parası',
                            style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Flexible(child: Text(
                          formatTry(widget.dues.principalAmount),
                          style: TextStyle(color: AppColors.textPrimary(context), fontSize: 12, fontWeight: FontWeight.w600),
                        )),
                      ],
                    ),
                    if (isOverdue) ...[
                      const SizedBox(height: 6),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Expanded(
                            child: Wrap(
                              crossAxisAlignment: WrapCrossAlignment.center,
                              runSpacing: 2,
                              children: [
                                Text('KMK %5 Kanuni Gecikme', style: TextStyle(color: AppColors.dangerText(context), fontSize: 12)),
                                const SizedBox(width: 4),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                                  decoration: BoxDecoration(
                                    color: AppColors.accentRed.withValues(alpha: 0.15),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(
                                    '${widget.dues.daysOverdue} gün',
                                    style: TextStyle(color: AppColors.dangerText(context), fontSize: 12, fontWeight: FontWeight.bold),
                                  ),
                                ),
                              ],
),
                          ),
                          const SizedBox(width: 6),
                          Flexible(child: Text(
                            '+${formatTry(widget.dues.delayPenalty)}',
                            style: TextStyle(color: AppColors.dangerText(context), fontSize: 12, fontWeight: FontWeight.bold),
                          )),
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
                        Flexible(child: Text(
                          formatTry(widget.dues.totalAmount),
                          style: TextStyle(color: AppColors.primaryText(context), fontWeight: FontWeight.bold, fontSize: 17),
                        )),
                      ],
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 16),

              // Free text amount entry section
              _buildAmountSection(),

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
                    child: testId('checkout_option_card', _buildMethodSelectorOption(
                      method: CheckoutPaymentMethod.card,
                      icon: Icons.credit_card,
                      title: 'Kredi Kartı',
                      subtitle: '3D Secure',
                    )),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: testId('checkout_option_virtual_iban', _buildMethodSelectorOption(
                      method: CheckoutPaymentMethod.virtualIban,
                      icon: Icons.account_balance,
                      title: 'Sanal IBAN',
                      subtitle: 'FAST / Havale',
                    )),
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

  Widget _buildAmountSection() {
    final debt = widget.dues.totalAmount;

    return Container(
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
              Flexible(child: Text(
                'Ödemek İstediğiniz Tutar',
                style: TextStyle(
                  color: AppColors.textPrimary(context),
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              )),
              if (debt > Decimal.zero)
                Text(
                  'Mevcut Borç: ${formatTry(debt)}',
                  style: TextStyle(
                    color: AppColors.textSecondary(context),
                    fontSize: 12,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _amountCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'^\d*[\.,]?\d{0,2}')),
            ],
            style: TextStyle(
              color: AppColors.textPrimary(context),
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
            decoration: InputDecoration(
              labelText: 'Tutar Giriniz (₺)',
              labelStyle: TextStyle(color: AppColors.textSecondary(context), fontSize: 12),
              prefixText: '₺ ',
              prefixStyle: TextStyle(
                color: AppColors.primaryText(context),
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
              suffixIcon: _amountCtrl.text.isNotEmpty
                  ? IconButton(
                      tooltip: 'Tutarı temizle',
                      icon: const Icon(Icons.clear, size: 16),
                      onPressed: () {
                        _amountCtrl.text = '';
                      },
                    )
                  : null,
              filled: true,
              fillColor: AppColors.background(context),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: AppColors.accentCyan, width: 1.5),
              ),
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            ),
          ),
          const SizedBox(height: 8),

          // Quick Preset Chips
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                if (debt > Decimal.zero) ...[
                  _buildQuickPresetChip(
                    label: 'Borcun Tamamı (${formatTry(debt)})',
                    amount: debt,
                  ),
                  const SizedBox(width: 6),
                  _buildQuickPresetChip(
                    label: '+₺500 Avans',
                    amount: debt + Decimal.parse('500.00'),
                  ),
                  const SizedBox(width: 6),
                  _buildQuickPresetChip(
                    label: '+₺1.000 Avans',
                    amount: debt + Decimal.parse('1000.00'),
                  ),
                ] else ...[
                  _buildQuickPresetChip(label: '₺500', amount: Decimal.parse('500.00')),
                  const SizedBox(width: 6),
                  _buildQuickPresetChip(label: '₺1.000', amount: Decimal.parse('1000.00')),
                  const SizedBox(width: 6),
                  _buildQuickPresetChip(label: '₺2.000', amount: Decimal.parse('2000.00')),
                  const SizedBox(width: 6),
                  _buildQuickPresetChip(label: '₺5.000', amount: Decimal.parse('5000.00')),
                ],
              ],
            ),
          ),
          const SizedBox(height: 10),

          // Dynamic calculation and allocation preview
          _buildAmountImpactBanner(),
        ],
      ),
    );
  }

  Widget _buildQuickPresetChip({required String label, required Decimal amount}) {
    final isSelected = _enteredAmount == amount;
    return InkWell(
      onTap: () {
        _amountCtrl.text = amount.toStringAsFixed(2);
      },
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
          color: isSelected
              ? AppColors.accentCyan.withValues(alpha: 0.15)
              : AppColors.background(context),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isSelected ? AppColors.accentCyan : AppColors.border(context),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isSelected ? AppColors.primaryText(context) : AppColors.textSecondary(context),
            fontSize: 12,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
          ),
        ),
      ),
    );
  }

  Widget _buildAmountImpactBanner() {
    final debt = widget.dues.totalAmount;
    if (_enteredAmount <= Decimal.zero) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: AppColors.accentRed.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Icon(Icons.warning_amber_rounded, size: 16, color: AppColors.accentRed),
            SizedBox(width: 6),
            Expanded(
              child: Text(
                'Lütfen geçerli bir ödeme tutarı giriniz.',
                style: TextStyle(color: AppColors.dangerText(context), fontSize: 12),
              ),
            ),
          ],
        ),
      );
    }

    if (debt > Decimal.zero) {
      if (_enteredAmount < debt) {
        final remaining = debt - _enteredAmount;
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.orange.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.orange.withValues(alpha: 0.3)),
          ),
          child: Row(
            children: [
              const Icon(Icons.info_outline, size: 16, color: Colors.orange),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Kısmi Ödeme: ${formatTry(_enteredAmount)} borçtan düşülecek • Kalan borç: ${formatTry(remaining)}',
                  style: const TextStyle(color: Colors.orange, fontSize: 12, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        );
      } else if (_enteredAmount == debt) {
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: AppColors.accentGreen.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppColors.accentGreen.withValues(alpha: 0.3)),
          ),
          child: Row(
            children: [
              Icon(Icons.check_circle_outline, size: 16, color: AppColors.accentGreen),
              SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Mevcut aidat borcunuzun tamamı kapatılacak.',
                  style: TextStyle(color: AppColors.successText(context), fontSize: 12, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        );
      } else {
        final surplus = _enteredAmount - debt;
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: AppColors.accentCyan.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppColors.accentCyan.withValues(alpha: 0.3)),
          ),
          child: Row(
            children: [
              const Icon(Icons.stars_rounded, size: 16, color: AppColors.accentCyan),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '${formatTry(debt)} borç kapatılacak • ${formatTry(surplus)} avans bakiyenize (Avans Bakiye) aktarılacak.',
                  style: TextStyle(color: AppColors.primaryText(context), fontSize: 12, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        );
      }
    } else {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: AppColors.accentGreen.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppColors.accentGreen.withValues(alpha: 0.3)),
        ),
        child: Row(
          children: [
            const Icon(Icons.account_balance_wallet_outlined, size: 16, color: AppColors.accentGreen),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                'Borcunuz bulunmuyor. ${formatTry(_enteredAmount)} tutarının tamamı avans bakiyenize (Avans Bakiye) aktarılacak.',
                style: TextStyle(color: AppColors.successText(context), fontSize: 12, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
      );
    }
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
                      color: isSelected ? AppColors.primaryText(context) : AppColors.textPrimary(context),
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    subtitle,
                    style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12),
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
                style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: _enteredAmount > Decimal.zero
                ? () {
                    Navigator.pop(context);
                    widget.onPaymentSuccess(_enteredAmount);
                  }
                : null,
            icon: const Icon(Icons.lock, size: 16),
            label: Text(
              widget.dues.totalAmount > Decimal.zero
                  ? '3D Secure ile ${formatTry(_enteredAmount)} Öde'
                  : '3D Secure ile ${formatTry(_enteredAmount)} Avans Yükle',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primaryFill,
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
                      style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12, fontWeight: FontWeight.w600),
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
                    child: Text(
                      'Otomatik Eşleşir',
                      style: TextStyle(color: AppColors.successText(context), fontSize: 12, fontWeight: FontWeight.bold),
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
                          appSnackBar(
                            content: Text('Sanal IBAN panoya kopyalandı!'),
                            duration: Duration(seconds: 2),
                            backgroundColor: AppColors.successFill,
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
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.copy, size: 12, color: AppColors.accentCyan),
                            SizedBox(width: 4),
                            Text(
                              AppStrings.copy,
                              style: TextStyle(color: AppColors.primaryText(context), fontSize: 12, fontWeight: FontWeight.bold),
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
                  Flexible(child: Text('Alıcı Adı:', style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12))),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${widget.siteName} Yönetimi',
                      textAlign: TextAlign.end,
                      style: TextStyle(color: AppColors.textPrimary(context), fontSize: 12, fontWeight: FontWeight.bold),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Flexible(child: Text('Banka:', style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12))),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'VakıfBank Kurumsal Havuz',
                      textAlign: TextAlign.end,
                      style: TextStyle(color: AppColors.textPrimary(context), fontSize: 12, fontWeight: FontWeight.bold),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Flexible(child: Text('Ödenecek Tutar:', style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12))),
                  Flexible(child: Text(formatTry(_enteredAmount), style: TextStyle(color: AppColors.primaryText(context), fontSize: 12, fontWeight: FontWeight.bold))),
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
                child: testId('checkout_fast_note', Text(
                  'Açıklama alanına hiçbir şey yazmanıza gerek yoktur. Bu IBAN sadece dairenize özeldir ve gönderdiğiniz tutar FAST ile saniyeler içinde aidat borcunuzu kapatır.',
                  style: TextStyle(color: AppColors.textPrimary(context), fontSize: 12, height: 1.35),
                )),
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
                appSnackBar(
                  content: Text('FAST transferiniz ulaştığında sistem borcunuzu otomatik kapatacak ve bildirim gönderecektir.'),
                  backgroundColor: AppColors.successFill,
                  duration: Duration(seconds: 4),
                ),
              );
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primaryFill,
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
