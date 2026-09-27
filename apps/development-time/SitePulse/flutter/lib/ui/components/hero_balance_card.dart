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

    return Container(
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF1E293B), Color(0xFF0F172A)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: hasPenalty ? AppColors.accentRed.withOpacity(0.5) : AppColors.darkBorder,
          width: 1.5,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.3),
            blurRadius: 16,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      padding: const EdgeInsets.all(22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    siteName,
                    style: const TextStyle(
                      color: AppColors.accentCyan,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.5,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '$unitName • ${dues.donem}',
                    style: const TextStyle(
                      color: AppColors.darkTextSecondary,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
              if (isOffline)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: AppColors.accentOrange.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppColors.accentOrange, width: 1),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.wifi_off, size: 14, color: AppColors.accentOrange),
                      SizedBox(width: 4),
                      Text(
                        'Çevrimdışı',
                        style: TextStyle(
                          color: AppColors.accentOrange,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                )
              else
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: hasPenalty
                        ? AppColors.accentRed.withOpacity(0.2)
                        : AppColors.accentGreen.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    hasPenalty ? '10 Gün Gecikme' : 'Vadesi Gelmedi',
                    style: TextStyle(
                      color: hasPenalty ? AppColors.accentRed : AppColors.accentGreen,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 18),
          const Text(
            'Ödenecek Toplam Tutar',
            style: TextStyle(
              color: AppColors.darkTextSecondary,
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 4),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                '₺${dues.toplamTutar.toStringAsFixed(2)}',
                style: const TextStyle(
                  color: AppColors.darkTextPrimary,
                  fontSize: 34,
                  fontWeight: FontWeight.bold,
                  letterSpacing: -0.5,
                ),
              ),
            ],
          ),
          if (hasPenalty) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: AppColors.accentRed.withOpacity(0.12),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  const Icon(Icons.info_outline, size: 15, color: AppColors.accentRed),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'Ana Para: ₺${dues.anaPara.toStringAsFixed(2)} + KMK %5 Kanuni Gecikme: ₺${dues.gecikmeTazminati.toStringAsFixed(2)}',
                      style: const TextStyle(
                        color: AppColors.accentRed,
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                flex: 3,
                child: ElevatedButton.icon(
                  onPressed: onPayPressed,
                  icon: const Icon(Icons.payment, size: 18, color: Colors.white),
                  label: const Text(
                    'Hemen Öde',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.accentCyan,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: OutlinedButton(
                  onPressed: onDetailPressed,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.darkTextPrimary,
                    side: const BorderSide(color: AppColors.darkBorder),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  child: const Text('Detay'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
