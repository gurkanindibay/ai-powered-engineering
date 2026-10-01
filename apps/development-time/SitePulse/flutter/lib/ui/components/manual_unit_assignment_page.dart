import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import '../../domain/models/dues_models.dart';
import '../theme/app_theme.dart';
import 'app_fullscreen_page.dart';

class ManualUnitAssignmentPage extends StatefulWidget {
  final List<FlatPaymentStatus> flats;
  final ReconciliationQueueItem item;

  const ManualUnitAssignmentPage({
    super.key,
    required this.flats,
    required this.item,
  });

  @override
  State<ManualUnitAssignmentPage> createState() => _ManualUnitAssignmentPageState();
}

class _ManualUnitAssignmentPageState extends State<ManualUnitAssignmentPage> {
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = AppColors.isDark(context);
    final txn = widget.item.transaction;

    final filteredFlats = widget.flats.where((f) {
      if (_searchQuery.isEmpty) return true;
      final query = _searchQuery.toLowerCase();
      final desc = f.flatDesc.toLowerCase();
      final name = f.residentName.toLowerCase();
      return desc.contains(query) || name.contains(query);
    }).toList();

    return AppFullscreenPage(
      title: 'Manuel Daire Eşleştirme',
      subtitle: 'Banka işlemini atanacak daire ile eşleştirin',
      icon: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: AppColors.accentCyan.withOpacity(0.15),
          borderRadius: BorderRadius.circular(10),
        ),
        child: const Icon(Icons.apartment, color: AppColors.accentCyan, size: 20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 1. Transaction Detail Card
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: isDark ? AppColors.darkSurface : AppColors.lightSurface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppColors.border(context)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'İşlem Tutarı',
                      style: TextStyle(
                        color: AppColors.textSecondary(context),
                        fontSize: 12,
                      ),
                    ),
                    Text(
                      '₺${txn.amount.toStringAsFixed(2)}',
                      style: const TextStyle(
                        color: AppColors.accentGreen,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  txn.description,
                  style: TextStyle(
                    color: AppColors.textPrimary(context),
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (txn.senderName != null) ...[
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      const Icon(Icons.person_outline, size: 14, color: AppColors.accentCyan),
                      const SizedBox(width: 4),
                      Text(
                        'Gönderen: ${txn.senderName}',
                        style: const TextStyle(
                          color: AppColors.accentCyan,
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),

          const SizedBox(height: 18),

          // 2. Search Field
          Container(
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.border(context)),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: TextField(
              controller: _searchController,
              onChanged: (val) {
                setState(() {
                  _searchQuery = val.trim();
                });
              },
              decoration: InputDecoration(
                icon: const Icon(Icons.search, size: 18, color: AppColors.accentCyan),
                border: InputBorder.none,
                hintText: 'Daire no, blok veya sakin adı ile filtreleyin...',
                hintStyle: TextStyle(color: AppColors.textSecondary(context), fontSize: 13),
              ),
            ),
          ),

          const SizedBox(height: 16),

          // 3. Section Title
          Text(
            'Site Sakinleri & Bağımsız Bölümler (${filteredFlats.length})',
            style: TextStyle(
              color: AppColors.textPrimary(context),
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),

          const SizedBox(height: 10),

          // 4. Flats List
          if (filteredFlats.isEmpty)
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: AppColors.surface(context),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: AppColors.border(context)),
              ),
              child: Center(
                child: Text(
                  'Arama kriterine uygun daire bulunamadı.',
                  style: TextStyle(color: AppColors.textSecondary(context), fontSize: 13),
                ),
              ),
            )
          else
            ...filteredFlats.map((flat) {
              final isExactAmount = (flat.amountDue == txn.amount);
              return Container(
                margin: const EdgeInsets.only(bottom: 10),
                decoration: BoxDecoration(
                  color: isDark ? AppColors.darkSurface : AppColors.lightSurface,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: isExactAmount ? AppColors.accentGreen : AppColors.border(context),
                    width: isExactAmount ? 1.5 : 1.0,
                  ),
                ),
                child: ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                  leading: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: isExactAmount
                          ? AppColors.accentGreen.withOpacity(0.15)
                          : AppColors.accentCyan.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(
                      Icons.home,
                      color: isExactAmount ? AppColors.accentGreen : AppColors.accentCyan,
                      size: 20,
                    ),
                  ),
                  title: Row(
                    children: [
                      Text(
                        flat.flatDesc,
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '• ${flat.residentName}',
                        style: TextStyle(
                          color: AppColors.textSecondary(context),
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                  subtitle: Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Row(
                      children: [
                        Text(
                          'Mevcut Borç: ₺${flat.amountDue.toStringAsFixed(2)}',
                          style: TextStyle(
                            fontSize: 12,
                            color: flat.amountDue > Decimal.zero
                                ? AppColors.accentOrange
                                : AppColors.accentGreen,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (isExactAmount) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: AppColors.accentGreen.withOpacity(0.15),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: const Text(
                              '%100 Tutar Eşleşmesi',
                              style: TextStyle(
                                color: AppColors.accentGreen,
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  trailing: const Icon(Icons.arrow_forward_ios, size: 14, color: AppColors.accentCyan),
                  onTap: () {
                    Navigator.pop(context, flat);
                  },
                ),
              );
            }),

          const SizedBox(height: 30),
        ],
      ),
    );
  }
}
