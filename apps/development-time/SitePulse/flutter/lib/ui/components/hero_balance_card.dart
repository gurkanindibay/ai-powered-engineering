import '../../testing/test_id.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../domain/models/dues_models.dart';
import '../theme/app_theme.dart';

class HeroBalanceCard extends StatelessWidget {
  final AidatBorcu dues;
  final String siteName;
  final String unitName;
  final bool isOffline;
  final VoidCallback onPayPressed;
  final VoidCallback onDetailPressed;
  final Decimal? advancePayment;
  final String? virtualIban;

  const HeroBalanceCard({
    super.key,
    required this.dues,
    required this.siteName,
    required this.unitName,
    required this.isOffline,
    required this.onPayPressed,
    required this.onDetailPressed,
    this.advancePayment,
    this.virtualIban,
  });

  @override
  Widget build(BuildContext context) {
    final debtDouble = dues.toplamTutar.toDouble();
    final advDouble = advancePayment?.toDouble() ?? 0.0;
    final hasPenalty = dues.gecikmeTazminati.toDouble() > 0 &&
        debtDouble > 0 &&
        dues.status != DebtStatus.paid;
    final isDark = AppColors.isDark(context);
    final hasAdvance = debtDouble <= 0 && advDouble > 0;

    // Format amount: e.g. 1423.33 → ₺1.423,33 (Turkish locale)
    final totalDouble = hasAdvance ? advDouble : debtDouble;
    final rawAmountText = _formatTurkishCurrency(totalDouble);
    final amountText = hasAdvance ? '+$rawAmountText' : rawAmountText;
    final debtFormatted = _formatTurkishCurrency(debtDouble);
    final advFormatted = '+${_formatTurkishCurrency(advDouble)}';

    final mainLabel = hasAdvance
        ? 'Toplam Hesap Bakiyesi (Artı Bakiye)'
        : (debtDouble > 0 ? 'Ödenecek Toplam Tutar' : 'Toplam Hesap Bakiyesi');

    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface(context),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: hasPenalty
              ? const Color(0xFFEF4444).withValues(alpha: 0.35)
              : (hasAdvance
                  ? const Color(0xFF10B981).withValues(alpha: 0.35)
                  : AppColors.border(context)),
          width: 1.0,
        ),
        boxShadow: isDark
            ? []
            : [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.04),
                  blurRadius: 10,
                  offset: const Offset(0, 2),
                ),
              ],
      ),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // ── 1. Unit Selector Capsule ──────────────────────────────────
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            decoration: BoxDecoration(
              color: isDark
                  ? const Color(0xFF141417)
                  : const Color(0xFFF1F3F5),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: AppColors.border(context), width: 1),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  siteName.isNotEmpty ? siteName : 'Site Tanımsız',
                  style: TextStyle(
                    color: AppColors.textPrimary(context),
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 5),
                const Text('🇹🇷', style: TextStyle(fontSize: 11)),
                const SizedBox(width: 5),
                Text(
                  unitName.trim().isNotEmpty && !unitName.endsWith('D:0') ? unitName : 'Daire Tanımsız',
                  style: TextStyle(
                    color: AppColors.textSecondary(context),
                    fontSize: 12,
                  ),
                ),
                const SizedBox(width: 4),
                Icon(
                  Icons.keyboard_arrow_down,
                  size: 15,
                  color: AppColors.textSecondary(context),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),

          // ── 2. Label ─────────────────────────────────────────────────
          testId('hero_balance_label', Text(
            mainLabel,
            style: TextStyle(
              color: hasAdvance ? const Color(0xFF10B981) : AppColors.textSecondary(context),
              fontSize: 12,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.2,
            ),
          )),
          const SizedBox(height: 8),

          // ── 3. Amount — full width, centered, 32px ────────────────────
          testId('hero_balance_amount', Text(
            amountText,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: hasAdvance ? const Color(0xFF10B981) : AppColors.textPrimary(context),
              fontSize: 32,
              fontWeight: FontWeight.w800,
              letterSpacing: -1.0,
            ),
          )),
          const SizedBox(height: 8),

          // ── 4. Status Pill ────────────────────────────────────────────
          if (hasPenalty)
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: const Color(0xFFEF4444).withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: const Color(0xFFEF4444).withValues(alpha: 0.3),
                  width: 1,
                ),
              ),
              child: testId('hero_overdue_badge', Text(
                '10 Gün Gecikme (%5 KMK)',
                style: const TextStyle(
                  color: Color(0xFFEF4444),
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              )),
            )
          else if (hasAdvance)
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: const Color(0xFF10B981).withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: const Color(0xFF10B981).withValues(alpha: 0.3),
                  width: 1,
                ),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.check_circle_outline, size: 13, color: Color(0xFF10B981)),
                  SizedBox(width: 4),
                  Text(
                    'Gelecek Dönem İçin Avans Mevcut',
                    style: TextStyle(
                      color: Color(0xFF10B981),
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            )
          else if (dues.donem.isEmpty || debtDouble <= 0)
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
              decoration: BoxDecoration(
                color: const Color(0xFF10B981).withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: const Color(0xFF10B981).withValues(alpha: 0.3),
                  width: 1,
                ),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.verified_outlined, size: 13, color: Color(0xFF10B981)),
                  SizedBox(width: 4),
                  Text(
                    'Aktif Aidat Borcu Bulunmuyor',
                    style: TextStyle(
                      color: Color(0xFF10B981),
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            )
          else
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: const Color(0xFF10B981).withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: const Color(0xFF10B981).withValues(alpha: 0.3),
                  width: 1,
                ),
              ),
              child: const Text(
                'Güncel — Borç Yok',
                style: TextStyle(
                  color: Color(0xFF10B981),
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          if ((dues.donem.isEmpty || debtDouble <= 0) && !hasAdvance) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF141417) : const Color(0xFFF1F3F5),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.border(context)),
              ),
              child: Row(
                children: [
                  const Text('💡', style: TextStyle(fontSize: 13)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Yönetim tarafından adınıza tahakkuk ettirilmiş aktif bir aidat borcu bulunmamaktadır. Gelecek dönemler için Sanal IBAN veya kredi kartınızla avans bakiye yükleyebilirsiniz.',
                      style: TextStyle(
                        color: AppColors.textSecondary(context),
                        fontSize: 11,
                        height: 1.35,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 14),

          // ── Dual Balance Breakdown Strip (Borç & Avans) ────────────────
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF141417) : const Color(0xFFF1F3F5),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppColors.border(context), width: 1),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Ödenecek Borç',
                        style: TextStyle(
                          color: AppColors.textSecondary(context),
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        debtFormatted,
                        style: TextStyle(
                          color: debtDouble > 0 ? const Color(0xFFEF4444) : AppColors.textPrimary(context),
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
                Container(
                  width: 1,
                  height: 26,
                  color: AppColors.border(context),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        'Avans Bakiye (Alacak)',
                        style: TextStyle(
                          color: AppColors.textSecondary(context),
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        advFormatted,
                        style: TextStyle(
                          color: advDouble > 0 ? const Color(0xFF10B981) : AppColors.textSecondary(context),
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),

          // ── 5. Action Buttons Row ─────────────────────────────────────
          Row(
            children: [
              Expanded(
                child: testId('btn_pay_now', _ActionButton(
                  label: hasAdvance || debtDouble <= 0 ? 'Avans Yükle' : 'Hemen Öde',
                  icon: hasAdvance || debtDouble <= 0 ? Icons.add_card_outlined : Icons.payments_outlined,
                  filled: true,
                  color: hasAdvance || debtDouble <= 0 ? const Color(0xFF10B981) : const Color(0xFFEF4444),
                  onTap: onPayPressed,
                )),
              ),
              const SizedBox(width: 10),
              // Detay / Hesap Özeti — ghost outline (secondary)
              Expanded(
                child: _ActionButton(
                  label: hasAdvance || debtDouble <= 0 ? 'Hesap Özeti' : 'Borç Detayı',
                  icon: hasAdvance || debtDouble <= 0 ? Icons.account_balance_wallet_outlined : Icons.receipt_long_outlined,
                  filled: false,
                  color: AppColors.textPrimary(context),
                  borderColor: AppColors.border(context),
                  onTap: onDetailPressed,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),

          // ── 6. IBAN Row ───────────────────────────────────────────────
          _IbanRow(
            iban: virtualIban ?? 'TR41 0020 5042 1399 1067 0000 14',
            context: context,
          ),
        ],
      ),
    );
  }

  /// Formats a double to Turkish currency style: ₺1.423,33
  static String _formatTurkishCurrency(double value) {
    final parts = value.toStringAsFixed(2).split('.');
    final intPart = parts[0];
    final decPart = parts[1];

    // Insert thousands separator (dot in Turkish)
    final buffer = StringBuffer();
    for (int i = 0; i < intPart.length; i++) {
      if (i > 0 && (intPart.length - i) % 3 == 0) {
        buffer.write('.');
      }
      buffer.write(intPart[i]);
    }
    return '₺${buffer.toString()},$decPart';
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Private: Pill-shaped action button (filled or ghost)
// ─────────────────────────────────────────────────────────────────────────────
class _ActionButton extends StatefulWidget {
  final String label;
  final IconData icon;
  final bool filled;
  final Color color;
  final Color? borderColor;
  final VoidCallback onTap;

  const _ActionButton({
    required this.label,
    required this.icon,
    required this.filled,
    required this.color,
    required this.onTap,
    this.borderColor,
  });

  @override
  State<_ActionButton> createState() => _ActionButtonState();
}

class _ActionButtonState extends State<_ActionButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) {
        setState(() => _pressed = false);
        widget.onTap();
      },
      onTapCancel: () => setState(() => _pressed = false),
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 100),
        opacity: _pressed ? 0.75 : 1.0,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 11),
          decoration: BoxDecoration(
            color: widget.filled ? widget.color : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
            border: widget.filled
                ? null
                : Border.all(
                    color: widget.borderColor ??
                        widget.color.withValues(alpha: 0.4),
                    width: 1.0,
                  ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                widget.icon,
                size: 17,
                color: widget.filled ? Colors.white : widget.color,
              ),
              const SizedBox(width: 6),
              Text(
                widget.label,
                style: TextStyle(
                  color: widget.filled ? Colors.white : widget.color,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Private: IBAN row with tap-to-copy
// ─────────────────────────────────────────────────────────────────────────────
class _IbanRow extends StatelessWidget {
  final String iban;
  final BuildContext context;

  const _IbanRow({required this.iban, required this.context});

  void _copyIban() {
    if (iban.trim().isEmpty) return;
    Clipboard.setData(ClipboardData(text: iban.replaceAll(' ', '')));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('IBAN kopyalandı'),
        duration: Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext ctx) {
    final hasIban = iban.trim().isNotEmpty;
    return testId('btn_copy_iban', GestureDetector(
      onTap: hasIban ? _copyIban : null,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            hasIban ? Icons.account_balance_outlined : Icons.info_outline,
            size: 13,
            color: AppColors.textSecondary(ctx),
          ),
          const SizedBox(width: 5),
          testId('virtual_iban_text', Text(
            hasIban ? 'Daire IBAN: $iban' : 'Sanal IBAN henüz tahsis edilmedi',
            style: TextStyle(
              color: AppColors.textSecondary(ctx),
              fontSize: 10.5,
              fontFamily: hasIban ? 'monospace' : null,
              letterSpacing: hasIban ? 0.3 : 0,
            ),
          )),
          if (hasIban) ...[
            const SizedBox(width: 5),
            Icon(
              Icons.copy_outlined,
              size: 13,
              color: AppColors.textSecondary(ctx),
            ),
          ],
        ],
      ),
    ));
  }
}
