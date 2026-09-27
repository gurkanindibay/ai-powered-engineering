import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

class ResidentActionsRow extends StatelessWidget {
  final bool isOwner;
  final VoidCallback onPayTap;
  final VoidCallback onIbanTap;
  final VoidCallback onReceiptsTap;
  final VoidCallback onInviteTap;

  const ResidentActionsRow({
    super.key,
    required this.isOwner,
    required this.onPayTap,
    required this.onIbanTap,
    required this.onReceiptsTap,
    required this.onInviteTap,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        _buildActionButton(
          context,
          icon: Icons.credit_card,
          label: 'Aidat Öde',
          color: AppColors.accentCyan,
          onTap: onPayTap,
        ),
        _buildActionButton(
          context,
          icon: Icons.account_balance,
          label: 'Sanal IBAN',
          color: AppColors.accentGreen,
          onTap: onIbanTap,
        ),
        _buildActionButton(
          context,
          icon: Icons.receipt_long,
          label: 'Dekontlar',
          color: AppColors.primary,
          onTap: onReceiptsTap,
        ),
        _buildActionButton(
          context,
          icon: Icons.person_add_alt_1,
          label: 'Sakin Davet',
          color: isOwner ? AppColors.accentOrange : AppColors.textSecondary(context),
          onTap: () {
            if (isOwner) {
              onInviteTap();
            } else {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Sadece Kat Maliki (Ev Sahibi) yeni sakin davet edebilir.'),
                  backgroundColor: AppColors.accentRed,
                ),
              );
            }
          },
          badgeText: isOwner ? 'Link Üret' : 'Yetki Yok',
        ),
      ],
    );
  }

  Widget _buildActionButton(
    BuildContext context, {
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
    String? badgeText,
  }) {
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 12),
            decoration: BoxDecoration(
              color: AppColors.surface(context),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppColors.border(context)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Stack(
                  alignment: Alignment.center,
                  clipBehavior: Clip.none,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: color.withOpacity(0.15),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(icon, color: color, size: 20),
                    ),
                    if (badgeText != null)
                      Positioned(
                        top: -4,
                        right: -10,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                          decoration: BoxDecoration(
                            color: isOwner ? AppColors.accentOrange : AppColors.border(context),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            badgeText,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 8,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  label,
                  style: TextStyle(
                    color: AppColors.textPrimary(context),
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
