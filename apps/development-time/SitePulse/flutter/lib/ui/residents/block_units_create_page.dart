import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_strings.dart';
import '../../testing/test_id.dart';
import '../components/app_fullscreen_page.dart';
import '../dashboard/dashboard_controller.dart';
import '../design_system/sp_feedback.dart';
import '../design_system/sp_guidance_card.dart';
import '../design_system/sp_money_field.dart';
import '../design_system/sp_tone.dart';
import '../theme/app_theme.dart';

/// Opens the manager's block & units form and reports whether a structure was
/// created, so the calling screen can show the confirmation toast.
Future<bool> showBlockUnitsCreatePage(
  BuildContext context,
  DashboardController controller,
) async {
  final created = await AppFullscreenPage.push<bool>(
    context: context,
    builder: (_) => BlockUnitsCreatePage(controller: controller),
  );
  if (created == true && context.mounted) {
    SpToast.success(context, 'Blok ve daireleri eklendi.');
  }
  return created == true;
}

/// Creates a block together with its units in one full-screen form (#285).
///
/// The manager gives the block name, the numbering of its units and optionally
/// a house type with its monthly tariff. Saving runs the two backend commands
/// (block, then units, with the tariff stored first when one is entered) and
/// pops with `true` once the unit directory has been reloaded.
class BlockUnitsCreatePage extends StatefulWidget {
  final DashboardController controller;

  const BlockUnitsCreatePage({super.key, required this.controller});

  /// Automation ids the GUI suite drives (`e2e/pages/manager.py`).
  static const nameId = 'block_form_name';
  static const startUnitId = 'block_form_start_unit';
  static const unitCountId = 'block_form_unit_count';
  static const totalFloorsId = 'block_form_total_floors';
  static const houseTypeId = 'block_form_house_type';
  static const monthlyDuesId = 'block_form_monthly_dues';
  static const errorId = 'block_form_error';
  static const submitId = 'btn_save_block_units';
  static const cancelId = 'btn_cancel_block_units';

  @override
  State<BlockUnitsCreatePage> createState() => _BlockUnitsCreatePageState();
}

class _BlockUnitsCreatePageState extends State<BlockUnitsCreatePage> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _startUnitController = TextEditingController(text: '1');
  final _unitCountController = TextEditingController();
  final _totalFloorsController = TextEditingController(text: '10');
  final _houseTypeController = TextEditingController();
  final _duesController = TextEditingController();

  Decimal? _monthlyDues;
  bool _isSaving = false;
  String? _error;

  @override
  void dispose() {
    _nameController.dispose();
    _startUnitController.dispose();
    _unitCountController.dispose();
    _totalFloorsController.dispose();
    _houseTypeController.dispose();
    _duesController.dispose();
    super.dispose();
  }

  String get _blockCode {
    final name = _nameController.text.trim();
    if (name.isEmpty) return '';
    return name
        .replaceAll(RegExp(r'\s*blok$', caseSensitive: false), '')
        .trim();
  }

  String? get _unitRangePreview {
    final start = int.tryParse(_startUnitController.text.trim());
    final count = int.tryParse(_unitCountController.text.trim());
    if (start == null ||
        count == null ||
        start < 1 ||
        count < 1 ||
        count > 500) {
      return null;
    }
    final code = _blockCode.isEmpty ? 'A' : _blockCode;
    final end = start + count - 1;
    final first = '$code-${start.toString().padLeft(2, '0')}';
    final last = '$code-${end.toString().padLeft(2, '0')}';
    return '$first … $last • $count daire';
  }

  Future<void> _save() async {
    if (_isSaving) return;
    setState(() => _error = null);
    if (!(_formKey.currentState?.validate() ?? false)) return;

    final houseType = _houseTypeController.text.trim();
    final duesText = _duesController.text.trim();
    if (duesText.isNotEmpty && houseType.isEmpty) {
      setState(() => _error = 'Aidat tanımlamak için konut tipi girin.');
      return;
    }

    setState(() => _isSaving = true);
    final error = await widget.controller.createBlockWithUnits(
      blockName: _nameController.text,
      startUnit: int.tryParse(_startUnitController.text.trim()) ?? 1,
      unitCount: int.tryParse(_unitCountController.text.trim()) ?? 0,
      totalFloors: int.tryParse(_totalFloorsController.text.trim()) ?? 10,
      houseType: houseType.isEmpty ? null : houseType,
      monthlyDues: duesText.isEmpty ? null : _monthlyDues,
    );
    if (!mounted) return;
    if (error != null) {
      setState(() {
        _isSaving = false;
        _error = error;
      });
      return;
    }
    Navigator.pop(context, true);
  }

  String? _requiredInt(
    String? value, {
    required String emptyMessage,
    required String rangeMessage,
    required int min,
    required int max,
  }) {
    final parsed = int.tryParse((value ?? '').trim());
    if (parsed == null) return emptyMessage;
    if (parsed < min || parsed > max) return rangeMessage;
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final controller = widget.controller;
    return AppFullscreenPage(
      title: 'Blok ve Daireleri Ekle',
      subtitle:
          '${controller.userSession.siteName} • Yeni blok ve dairelerini tek adımda oluşturun',
      icon: const Icon(Icons.apartment, color: AppColors.accentCyan),
      bottomBar: AppFullscreenPage.buildBottomBar(
        context: context,
        children: [
          testId(
            BlockUnitsCreatePage.cancelId,
            OutlinedButton(
              key: const Key(BlockUnitsCreatePage.cancelId),
              onPressed: _isSaving ? null : () => Navigator.pop(context, false),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.textPrimary(context),
                side: BorderSide(color: AppColors.border(context)),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppRadius.control),
                ),
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              child: const Text(AppStrings.cancel),
            ),
          ),
          testId(
            BlockUnitsCreatePage.submitId,
            ElevatedButton.icon(
              key: const Key(BlockUnitsCreatePage.submitId),
              onPressed: _isSaving ? null : _save,
              icon: _isSaving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.add_home_work_outlined, size: 18),
              label: Text(_isSaving ? 'Kaydediliyor...' : 'Bloğu Oluştur'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primaryFill,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppRadius.control),
                ),
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
            ),
          ),
        ],
      ),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SpGuidanceCard(
              icon: Icons.info_outline,
              tone: SpTone.info,
              title: 'Blok ve daireler birlikte oluşturulur',
              message:
                  'Blok adını ve daire numaralarını girin. Kaydettiğinizde blok açılır, '
                  'daireler boş olarak eklenir. İsteğe bağlı konut tipi ve aylık aidat girerseniz '
                  'tarife de tanımlanır.',
              tip: 'Daireler "A Blok 1", "A Blok 2" gibi etiketlenir; numaralandırma sizin girdiğiniz başlangıçtan başlar.',
            ),
            const SizedBox(height: AppSpacing.lg),
            testId(
              BlockUnitsCreatePage.nameId,
              TextFormField(
                key: const Key(BlockUnitsCreatePage.nameId),
                controller: _nameController,
                textInputAction: TextInputAction.next,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  labelText: 'Blok adı',
                  hintText: 'örn. A Blok',
                ),
                validator: (value) {
                  final name = (value ?? '').trim();
                  if (name.isEmpty) return 'Blok adı girin.';
                  if (name.length > 60)
                    return 'Blok adı en fazla 60 karakter olabilir.';
                  return null;
                },
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: testId(
                    BlockUnitsCreatePage.startUnitId,
                    TextFormField(
                      key: const Key(BlockUnitsCreatePage.startUnitId),
                      controller: _startUnitController,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      textInputAction: TextInputAction.next,
                      onChanged: (_) => setState(() {}),
                      decoration: const InputDecoration(
                        labelText: 'Başlangıç daire no',
                        hintText: '1',
                      ),
                      validator: (value) => _requiredInt(
                        value,
                        emptyMessage: 'Başlangıç numarası girin.',
                        rangeMessage: '1 ile 9999 arasında olmalıdır.',
                        min: 1,
                        max: 9999,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: testId(
                    BlockUnitsCreatePage.unitCountId,
                    TextFormField(
                      key: const Key(BlockUnitsCreatePage.unitCountId),
                      controller: _unitCountController,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      textInputAction: TextInputAction.next,
                      onChanged: (_) => setState(() {}),
                      decoration: const InputDecoration(
                        labelText: 'Daire sayısı',
                        hintText: '7',
                      ),
                      validator: (value) => _requiredInt(
                        value,
                        emptyMessage: 'Daire sayısı girin.',
                        rangeMessage: '1 ile 500 arasında olmalıdır.',
                        min: 1,
                        max: 500,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            testId(
              BlockUnitsCreatePage.totalFloorsId,
              TextFormField(
                key: const Key(BlockUnitsCreatePage.totalFloorsId),
                controller: _totalFloorsController,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(
                  labelText: 'Kat sayısı',
                  hintText: '10',
                ),
                validator: (value) => _requiredInt(
                  value,
                  emptyMessage: 'Kat sayısı girin.',
                  rangeMessage: '1 ile 100 arasında olmalıdır.',
                  min: 1,
                  max: 100,
                ),
              ),
            ),
            if (_unitRangePreview != null) ...[
              const SizedBox(height: AppSpacing.sm),
              testId(
                'block_form_range_preview',
                Text(
                  _unitRangePreview!,
                  key: const Key('block_form_range_preview'),
                  style: text.bodySmall?.copyWith(
                    color: AppColors.textSecondary(context),
                  ),
                ),
              ),
            ],
            const SizedBox(height: AppSpacing.lg),
            Text('Aidat tarifesi (isteğe bağlı)', style: text.titleSmall),
            const SizedBox(height: AppSpacing.xs),
            testId(
              BlockUnitsCreatePage.houseTypeId,
              TextFormField(
                key: const Key(BlockUnitsCreatePage.houseTypeId),
                controller: _houseTypeController,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(
                  labelText: 'Konut tipi',
                  hintText: 'örn. 2+1',
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            testId(
              BlockUnitsCreatePage.monthlyDuesId,
              SpMoneyFormField(
                key: const Key(BlockUnitsCreatePage.monthlyDuesId),
                controller: _duesController,
                required: false,
                positive: true,
                onAmountChanged: (amount) => _monthlyDues = amount,
                decoration: const InputDecoration(
                  labelText: 'Aylık aidat',
                  helperText:
                      'Konut tipiyle birlikte girildiğinde tarife kaydedilir.',
                ),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: AppSpacing.md),
              testId(
                BlockUnitsCreatePage.errorId,
                Text(
                  _error!,
                  key: const Key(BlockUnitsCreatePage.errorId),
                  style: text.bodyMedium?.copyWith(
                    color: SpTone.danger.foreground(context),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
