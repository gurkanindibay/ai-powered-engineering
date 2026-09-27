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

  const HeroBalanceCard({
    super.key,
    required this.dues,
    required this.siteName,
    required this.unitName,
    required this.isOffline,
    required this.onPayPressed,
    required this.onDetailPressed,
  });

  @override
  Widget build(BuildContext context) {
    final hasPenalty = dues.gecikmeTazminati.toDouble() > 0;
    final isDark = AppColors.isDark(context);

    // Format amount: e.g. 1423.33 → ₺1.423,33 (Turkish locale)
    final totalDouble = dues.toplamTutar.toDouble();
    final amountText = _formatTurkishCurrency(totalDouble);

    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface(context),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: hasPenalty
              ? const Color(0xFFEF4444).withValues(alpha: 0.35)
              : AppColors.border(context),
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
                  siteName,
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
                  unitName,
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
          Text(
            'Ödenecek Toplam Tutar',
            style: TextStyle(
              color: AppColors.textSecondary(context),
              fontSize: 12,
              fontWeight: FontWeight.w500,
              letterSpacing: 0.2,
            ),
          ),
          const SizedBox(height: 8),

          // ── 3. Amount — full width, centered, 32px ────────────────────
          Text(
            amountText,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppColors.textPrimary(context),
              fontSize: 32,
              fontWeight: FontWeight.w800,
              letterSpacing: -1.0,
            ),
          ),
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
              child: Text(
                '10 Gün Gecikme (%5 KMK)',
                style: const TextStyle(
                  color: Color(0xFFEF4444),
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
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
                'Güncel — Gecikme Yok',
                style: TextStyle(
                  color: Color(0xFF10B981),
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          const SizedBox(height: 16),

          // ── 5. Action Buttons Row ─────────────────────────────────────
          Row(
            children: [
              // Hemen Öde — solid red (high urgency CTA)
              Expanded(
                child: _ActionButton(
                  label: 'Hemen Öde',
                  icon: Icons.payments_outlined,
                  filled: true,
                  color: const Color(0xFFEF4444),
                  onTap: onPayPressed,
                ),
              ),
              const SizedBox(width: 10),
              // Detay — ghost outline (secondary)
              Expanded(
                child: _ActionButton(
                  label: 'Detay',
                  icon: Icons.receipt_long_outlined,
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
            iban: 'TR12 0006 2000 0000 0000 0014',
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
    return GestureDetector(
      onTap: _copyIban,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            'Daire IBAN: $iban',
            style: TextStyle(
              color: AppColors.textSecondary(ctx),
              fontSize: 10.5,
              fontFamily: 'monospace',
              letterSpacing: 0.3,
            ),
          ),
          const SizedBox(width: 5),
          Icon(
            Icons.copy_outlined,
            size: 13,
            color: AppColors.textSecondary(ctx),
          ),
        ],
      ),
    );
  }
}
