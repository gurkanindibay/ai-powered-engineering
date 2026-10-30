import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

class ResidentActionsRow extends StatelessWidget {
  final bool isOwner;
  final VoidCallback onReceiptsTap;
  final VoidCallback onInviteTap;
  final VoidCallback onRequestsTap;
  final VoidCallback onAnnouncementsTap;

  const ResidentActionsRow({
    super.key,
    required this.isOwner,
    required this.onReceiptsTap,
    required this.onInviteTap,
    required this.onRequestsTap,
    required this.onAnnouncementsTap,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        // 1. Receipts & Past Statements
        _buildActionButton(
          context,
          icon: Icons.receipt_long_outlined,
          label: 'Dekontlar',
          color: AppColors.primary,
          onTap: onReceiptsTap,
        ),
        // 2. Invite Resident / Family
        _buildActionButton(
          context,
          icon: Icons.person_add_alt_1_outlined,
          label: 'Sakin Davet',
          color: AppColors.accentOrange,
          badgeText: isOwner ? 'Malik' : 'Sakin',
          badgeColor: AppColors.accentOrange,
          onTap: onInviteTap,
        ),
        // 3. Maintenance Request / Issue Reporting
        _buildActionButton(
          context,
          icon: Icons.build_circle_outlined,
          label: 'Talep / Arıza',
          color: AppColors.accentCyan,
          badgeText: 'Bildir',
          badgeColor: AppColors.accentCyan,
          onTap: onRequestsTap,
        ),
        // 4. Site Announcements
        _buildActionButton(
          context,
          icon: Icons.campaign_outlined,
          label: 'Duyurular',
          color: AppColors.accentGreen,
          badgeText: '3 Yeni',
          badgeColor: AppColors.accentGreen,
          onTap: onAnnouncementsTap,
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
    Color? badgeColor,
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
                        color: color.withValues(alpha: 0.15),
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
                            color: badgeColor ?? (isOwner ? AppColors.accentOrange : AppColors.border(context)),
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
