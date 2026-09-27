import 'package:flutter/material.dart';
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

    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface(context),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: hasPenalty
              ? const Color(0xFFEF4444).withOpacity(0.4)
              : AppColors.border(context),
          width: 1.0,
        ),
        boxShadow: isDark
            ? []
            : [
                BoxShadow(
                  color: Colors.black.withOpacity(0.04),
                  blurRadius: 10,
                  offset: const Offset(0, 2),
                ),
              ],
      ),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // 1. Top Unit Selector Capsule (Papara "Türk Lirası 🇹🇷 TL ⌵" style)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF141417) : const Color(0xFFF1F3F5),
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
          const SizedBox(height: 12),

          // 2. Subtitle: "Ödenecek Toplam Tutar"
          Text(
            'Ödenecek Toplam Tutar',
            style: TextStyle(
              color: AppColors.textSecondary(context),
              fontSize: 12,
              fontWeight: FontWeight.w500,
              letterSpacing: 0.2,
            ),
          ),
          const SizedBox(height: 14),

          // 3. Floating Balance Row with Circular Action Buttons (Papara [-] and [+] style)
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // Left Circular Action Button: [-] Hemen Öde (Papara Çek Red Circle)
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  InkWell(
                    onTap: onPayPressed,
                    borderRadius: BorderRadius.circular(28),
                    child: Container(
                      width: 54,
                      height: 54,
                      decoration: BoxDecoration(
                        color: isDark ? const Color(0xFF1C1D24) : Colors.white,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: const Color(0xFFEF4444),
                          width: 2.0,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: const Color(0xFFEF4444).withOpacity(0.15),
                            blurRadius: 8,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: const Center(
                        child: Icon(
                          Icons.remove,
                          color: Color(0xFFEF4444),
                          size: 26,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Hemen Öde',
                    style: TextStyle(
                      color: AppColors.textSecondary(context),
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),

              // Center: Bold Balance Typography
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '₺${dues.toplamTutar.toStringAsFixed(2)}',
                    style: TextStyle(
                      color: AppColors.textPrimary(context),
                      fontSize: 34,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.5,
                    ),
                  ),
                  if (hasPenalty) ...[
                    const SizedBox(height: 4),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: const Color(0xFFEF4444).withOpacity(0.12),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Text(
                        '10 Gün Gecikme (%5 KMK)',
                        style: TextStyle(
                          color: Color(0xFFEF4444),
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ],
              ),

              // Right Circular Action Button: [+] Detay (Papara Yatır Green Circle)
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  InkWell(
                    onTap: onDetailPressed,
                    borderRadius: BorderRadius.circular(28),
                    child: Container(
                      width: 54,
                      height: 54,
                      decoration: BoxDecoration(
                        color: isDark ? const Color(0xFF1C1D24) : Colors.white,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: const Color(0xFF10B981),
                          width: 2.0,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: const Color(0xFF10B981).withOpacity(0.15),
                            blurRadius: 8,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: const Center(
                        child: Icon(
                          Icons.add,
                          color: Color(0xFF10B981),
                          size: 26,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Detay',
                    style: TextStyle(
                      color: AppColors.textSecondary(context),
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 14),

          // 4. Centered IBAN reference (Papara style IBAN preview)
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                "Daire IBAN: TR12 0006 2000 0000 0000 0014",
                style: TextStyle(
                  color: AppColors.textSecondary(context),
                  fontSize: 11,
                  fontFamily: 'monospace',
                ),
              ),
              const SizedBox(width: 4),
              Icon(
                Icons.copy,
                size: 13,
                color: AppColors.textSecondary(context),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
