import '../../testing/test_id.dart';
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
                child: Material(
                  color: Colors.transparent,
                  borderRadius: BorderRadius.circular(14),
                  child: testId('assign_flat_${flat.id}', ListTile(
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
                    onTap: () => _confirmAssignment(flat),
                  )),
                ),
              );
            }),

          const SizedBox(height: 30),
        ],
      ),
    );
  }

  Future<void> _confirmAssignment(FlatPaymentStatus flat) async {
    final txn = widget.item.transaction;
    bool sendMessage = true;
    bool rememberIban = txn.senderIban != null && txn.senderIban!.isNotEmpty;
    final messageController = TextEditingController(
      text:
          'Sayın ${flat.residentName}, ${flat.flatDesc} nolu dairenize ait ₺${txn.amount.toStringAsFixed(2)} tutarındaki aidat ödemeniz banka hareketleri ile eşleştirilmiş ve onaylanmıştır. Teşekkür ederiz.',
    );

    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (dialogCtx, setDialogState) {
            final isDark = AppColors.isDark(dialogCtx);
            return Dialog(
              backgroundColor: isDark ? AppColors.darkSurface : AppColors.lightSurface,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
              child: Container(
                constraints: const BoxConstraints(maxWidth: 520),
                padding: const EdgeInsets.all(24),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Header
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: AppColors.accentCyan.withOpacity(0.15),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: const Icon(Icons.verified_user_outlined, color: AppColors.accentCyan, size: 24),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Ev Sahibi & Ödeme Eşleştirme Onayı',
                                  style: TextStyle(
                                    color: AppColors.textPrimary(dialogCtx),
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  'Ödemeyi ev sahibi ile eşleştirin ve bildirim gönderin',
                                  style: TextStyle(
                                    color: AppColors.textSecondary(dialogCtx),
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            onPressed: () => Navigator.pop(dialogCtx, false),
                            icon: const Icon(Icons.close, size: 20),
                            color: AppColors.textSecondary(dialogCtx),
                          ),
                        ],
                      ),
                      const SizedBox(height: 18),

                      // Host / Unit Info Card
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: AppColors.surface(dialogCtx),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: AppColors.border(dialogCtx)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const Icon(Icons.apartment, color: AppColors.accentCyan, size: 16),
                                const SizedBox(width: 6),
                                Text(
                                  'Daire / Ev Sahibi: ${flat.flatDesc}',
                                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            Text(
                              'Kat Maliki / Sakin: ${flat.residentName}',
                              style: TextStyle(color: AppColors.textPrimary(dialogCtx), fontSize: 12),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Mevcut Borç: ₺${flat.amountDue.toStringAsFixed(2)}',
                              style: TextStyle(
                                color: flat.amountDue > Decimal.zero ? AppColors.accentOrange : AppColors.accentGreen,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),

                      // Payment Info Card
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: AppColors.accentGreen.withOpacity(0.08),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: AppColors.accentGreen.withOpacity(0.3)),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text(
                                    'Eşleştirilecek Ödeme Tutarı',
                                    style: TextStyle(fontSize: 11, color: AppColors.accentGreen, fontWeight: FontWeight.w600),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    '₺${txn.amount.toStringAsFixed(2)}',
                                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AppColors.accentGreen),
                                  ),
                                  if (txn.senderName != null) ...[
                                    const SizedBox(height: 4),
                                    Text(
                                      'Gönderen: ${txn.senderName}',
                                      style: TextStyle(fontSize: 11, color: AppColors.textSecondary(dialogCtx)),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                            const Icon(Icons.link, color: AppColors.accentGreen, size: 28),
                          ],
                        ),
                      ),
                      const SizedBox(height: 14),

                      // Remember Sender IBAN Option for Site Manager
                      if (txn.senderIban != null && txn.senderIban!.isNotEmpty) ...[
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                          decoration: BoxDecoration(
                            color: rememberIban
                                ? AppColors.accentCyan.withOpacity(0.08)
                                : AppColors.surface(dialogCtx),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: rememberIban
                                  ? AppColors.accentCyan.withOpacity(0.35)
                                  : AppColors.border(dialogCtx),
                            ),
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Checkbox(
                                value: rememberIban,
                                activeColor: AppColors.accentCyan,
                                onChanged: (val) {
                                  setDialogState(() {
                                    rememberIban = val ?? true;
                                  });
                                },
                              ),
                              Expanded(
                                child: GestureDetector(
                                  onTap: () {
                                    setDialogState(() {
                                      rememberIban = !rememberIban;
                                    });
                                  },
                                  child: Padding(
                                    padding: const EdgeInsets.only(top: 8),
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          'Bu Gönderici IBAN\'ını ${flat.flatDesc} ile Kalıcı Eşle',
                                          style: TextStyle(
                                            color: AppColors.textPrimary(dialogCtx),
                                            fontSize: 12.5,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                        const SizedBox(height: 3),
                                        Text(
                                          'Gelecek ödemelerde bu hesaptan (${txn.senderIban}) yapılan transferler açıklama boş olsa dahi otomatik olarak ${flat.flatDesc} (${flat.residentName}) ile eşleştirilecektir.',
                                          style: TextStyle(
                                            color: AppColors.textSecondary(dialogCtx),
                                            fontSize: 11,
                                            height: 1.35,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 14),
                      ],

                      // Optional Message Request Section
                      Row(
                        children: [
                          Checkbox(
                            value: sendMessage,
                            activeColor: AppColors.accentCyan,
                            onChanged: (val) {
                              setDialogState(() {
                                sendMessage = val ?? false;
                              });
                            },
                          ),
                          Expanded(
                            child: GestureDetector(
                              onTap: () {
                                setDialogState(() {
                                  sendMessage = !sendMessage;
                                });
                              },
                              child: Text(
                                'Ev Sahibine Bilgilendirme Mesajı Gönder (Opsiyonel)',
                                style: TextStyle(
                                  color: AppColors.textPrimary(dialogCtx),
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      if (sendMessage) ...[
                        const SizedBox(height: 6),
                        TextField(
                          controller: messageController,
                          maxLines: 3,
                          style: TextStyle(color: AppColors.textPrimary(dialogCtx), fontSize: 12),
                          decoration: InputDecoration(
                            hintText: 'Ev sahibine iletilecek mesaj metnini düzenleyebilirsiniz...',
                            filled: true,
                            fillColor: isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide(color: AppColors.border(dialogCtx)),
                            ),
                            contentPadding: const EdgeInsets.all(12),
                          ),
                        ),
                      ],

                      const SizedBox(height: 22),

                      // Actions
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              onPressed: () => Navigator.pop(dialogCtx, false),
                              style: OutlinedButton.styleFrom(
                                padding: const EdgeInsets.symmetric(vertical: 12),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                              ),
                              child: const Text('Vazgeç'),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: testId('btn_confirm_assignment', ElevatedButton.icon(
                              onPressed: () => Navigator.pop(dialogCtx, true),
                              icon: const Icon(Icons.check, size: 16),
                              label: const Text('Eşleştirmeyi Onayla'),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: AppColors.accentGreen,
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(vertical: 12),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                              ),
                            )),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );

    if (confirmed == true && mounted) {
      Navigator.pop(
        context,
        ManualAssignmentResult(
          flat: flat,
          sendOptionalMessage: sendMessage,
          optionalMessageText: sendMessage ? messageController.text.trim() : null,
          rememberSenderIban: rememberIban,
        ),
      );
    }
  }
}
