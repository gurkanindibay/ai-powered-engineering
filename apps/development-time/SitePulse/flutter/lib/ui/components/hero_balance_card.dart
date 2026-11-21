import '../../testing/test_id.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import '../../domain/models/dues_models.dart';
import '../theme/app_theme.dart';

import '../design_system/money_formatter.dart';
import '../design_system/sp_clipboard.dart';
import '../design_system/sp_status_badge.dart';
import '../design_system/sp_tone.dart';
class HeroBalanceCard extends StatelessWidget {
  final DuesLiability dues;
  final String siteName;
  final String unitName;
  final bool isOffline;
  final VoidCallback onPayPressed;
  final VoidCallback onDetailPressed;
  final Decimal? advancePayment;
  final String? virtualIban;
  final List<CapitalDuesSummary> capitalDues;

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
    this.capitalDues = const [],
  });

  @override
  Widget build(BuildContext context) {
    final debt = dues.totalAmount;
    final advance = advancePayment ?? Decimal.zero;
    final hasPenalty = dues.delayPenalty > Decimal.zero &&
        debt > Decimal.zero &&
        dues.status != DebtStatus.paid;
    final isDark = AppColors.isDark(context);
    final hasAdvance = debt <= Decimal.zero && advance > Decimal.zero;

    // Decimal all the way: 1423.33 → ₺1.423,33 (Turkish locale), never through double.
    final rawAmountText = MoneyFormatter.format(hasAdvance ? advance : debt);
    final amountText = hasAdvance ? '+$rawAmountText' : rawAmountText;
    final debtFormatted = MoneyFormatter.format(debt);
    final advFormatted = MoneyFormatter.formatCredit(advance);
    final capitalTotal = capitalDues.fold<Decimal>(
      Decimal.zero,
      (total, item) => total + item.outstandingBalance,
    );

    final mainLabel = hasAdvance
        ? 'Toplam Hesap Bakiyesi (Artı Bakiye)'
        : (debt > Decimal.zero ? 'Ödenecek Toplam Tutar' : 'Toplam Hesap Bakiyesi');

    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface(context),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: hasPenalty
              ? AppColors.accentRed.withValues(alpha: 0.35)
              : (hasAdvance
                  ? AppColors.accentGreen.withValues(alpha: 0.35)
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
            child: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              runSpacing: 8,
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
                const ExcludeSemantics(child: Icon(Icons.location_on_outlined, size: 14, color: AppColors.accentCyan)),
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
              ]),
          ),
          const SizedBox(height: 8),
          testId(
            'capital_owner_badge',
            const SpStatusBadge(
              label: 'Kat Maliki Sorumluluğunda',
              tone: SpTone.info,
              icon: Icons.home_work_outlined,
            ),
          ),
          const SizedBox(height: 14),

          // ── 2. Label ─────────────────────────────────────────────────
          testId('hero_balance_label', Text(
            mainLabel,
            style: TextStyle(
              color: hasAdvance ? AppColors.successText(context) : AppColors.textSecondary(context),
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
              color: hasAdvance ? AppColors.successText(context) : AppColors.textPrimary(context),
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
                color: AppColors.accentRed.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: AppColors.accentRed.withValues(alpha: 0.3),
                  width: 1,
                ),
              ),
              child: testId('hero_overdue_badge', Text(
                '${dues.daysOverdue} Gün Gecikme (%5 KMK)',
                style: TextStyle(
                  color: AppColors.dangerText(context),
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              )),
            )
          else if (hasAdvance)
            testId('hero_advance_pill', Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: AppColors.accentGreen.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: AppColors.accentGreen.withValues(alpha: 0.3),
                  width: 1,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.check_circle_outline, size: 13, color: AppColors.accentGreen),
                  SizedBox(width: 4),
                  Text(
                    'Gelecek Dönem İçin Avans Mevcut',
                    style: TextStyle(
                      color: AppColors.successText(context),
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ))
          else if (dues.period.isEmpty || debt <= Decimal.zero)
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
              decoration: BoxDecoration(
                color: AppColors.accentGreen.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: AppColors.accentGreen.withValues(alpha: 0.3),
                  width: 1,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.verified_outlined, size: 13, color: AppColors.accentGreen),
                  SizedBox(width: 4),
                  Text(
                    'Aktif Aidat Borcu Bulunmuyor',
                    style: TextStyle(
                      color: AppColors.successText(context),
                      fontSize: 12,
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
                color: AppColors.accentGreen.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: AppColors.accentGreen.withValues(alpha: 0.3),
                  width: 1,
                ),
              ),
              child: Text(
                'Güncel — Borç Yok',
                style: TextStyle(
                  color: AppColors.successText(context),
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          if ((dues.period.isEmpty || debt <= Decimal.zero) && !hasAdvance) ...[
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
                  const ExcludeSemantics(child: Icon(Icons.lightbulb_outline_rounded, size: 16, color: AppColors.accentOrange)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Yönetim tarafından adınıza tahakkuk ettirilmiş aktif bir aidat borcu bulunmamaktadır. Gelecek dönemler için Sanal IBAN veya kredi kartınızla avans bakiye yükleyebilirsiniz.',
                      style: TextStyle(
                        color: AppColors.textSecondary(context),
                        fontSize: 12,
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
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        debtFormatted,
                        style: TextStyle(
                          color: debt > Decimal.zero ? AppColors.dangerText(context) : AppColors.textPrimary(context),
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
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        advFormatted,
                        style: TextStyle(
                          color: advance > Decimal.zero ? AppColors.successText(context) : AppColors.textSecondary(context),
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

          if (capitalDues.isNotEmpty) ...[
            Divider(color: AppColors.border(context), height: 1),
            const SizedBox(height: 12),
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Demirbaş Toplamı',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                testId(
                  'hero_capital_balance',
                  Text(
                    MoneyFormatter.format(capitalTotal),
                    style: TextStyle(
                      color: SpTone.accent.foreground(context),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            for (final item in capitalDues)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  children: [
                    Expanded(child: Text(item.projectTitle, maxLines: 2, overflow: TextOverflow.ellipsis)),
                    const SizedBox(width: 12),
                    Text(MoneyFormatter.format(item.outstandingBalance)),
                  ],
                ),
              ),
            const SizedBox(height: 14),
          ],

          // ── 5. Action Buttons Row ─────────────────────────────────────
          Row(
            children: [
              Expanded(
                child: testId('btn_pay_now', _ActionButton(
                  label: hasAdvance || debt <= Decimal.zero ? 'Avans Yükle' : 'Hemen Öde',
                  icon: hasAdvance || debt <= Decimal.zero ? Icons.add_card_outlined : Icons.payments_outlined,
                  filled: true,
                  color: hasAdvance || debt <= Decimal.zero ? AppColors.successFill : AppColors.dangerFill,
                  onTap: onPayPressed,
                )),
              ),
              const SizedBox(width: 10),
              // Detay / Hesap Özeti — ghost outline (secondary)
              Expanded(
                child: testId('hero_detail_button', _ActionButton(
                  label: hasAdvance || debt <= Decimal.zero ? 'Hesap Özeti' : 'Borç Detayı',
                  icon: hasAdvance || debt <= Decimal.zero ? Icons.account_balance_wallet_outlined : Icons.receipt_long_outlined,
                  filled: false,
                  color: AppColors.textPrimary(context),
                  borderColor: AppColors.border(context),
                  onTap: onDetailPressed,
                )),
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
    // GestureDetector's onTapUp is invisible to screen readers, so the button
    // role, label and tap action are declared explicitly.
    return Semantics(
      button: true,
      label: widget.label,
      onTap: widget.onTap,
      excludeSemantics: true,
      child: GestureDetector(
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
          constraints: const BoxConstraints(minHeight: kMinTouchTarget),
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
              Flexible(
                child: Text(
                  widget.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: widget.filled ? Colors.white : widget.color,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ));
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Private: IBAN row with tap-to-copy
// ─────────────────────────────────────────────────────────────────────────────
class _IbanRow extends StatelessWidget {
  final String iban;
  final BuildContext context;

  const _IbanRow({required this.iban, required this.context});

  Future<void> _copyIban() => spCopyIban(context, iban, successMessage: 'IBAN kopyalandı');

  @override
  Widget build(BuildContext ctx) {
    final hasIban = iban.trim().isNotEmpty;
    return testId('btn_copy_iban', Semantics(
      button: hasIban,
      hint: hasIban ? 'IBAN\'ı kopyalamak için dokunun' : null,
      child: GestureDetector(
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
          Flexible(child: testId('virtual_iban_text', Text(
            hasIban ? 'Daire IBAN: $iban' : 'Sanal IBAN henüz tahsis edilmedi',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppColors.textSecondary(ctx),
              fontSize: 12,
              fontFamily: hasIban ? 'monospace' : null,
              letterSpacing: hasIban ? 0.3 : 0,
            ),
          ))),
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
    )));
  }
}
