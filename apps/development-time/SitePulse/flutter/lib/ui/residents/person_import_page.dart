import 'dart:convert';

import 'package:flutter/material.dart';

import '../../domain/services/api_client.dart';
import '../../domain/services/bank_file_picker.dart';
import '../../domain/services/person_directory_api.dart';
import '../../domain/services/platform_env.dart';
import '../../testing/test_id.dart';
import '../components/app_fullscreen_page.dart';
import '../design_system/sp_feedback.dart';
import '../design_system/sp_guidance_card.dart';
import '../design_system/sp_status_badge.dart';
import '../design_system/sp_tone.dart';
import '../theme/app_theme.dart';

/// Registers many owners from a CSV file (person module F8). The file is checked
/// first (a dry run that changes nothing); the import button is enabled only once
/// that check finds no errors, and only for the exact text that was checked.
/// Pops with `true` when rows were registered.
class PersonImportPage extends StatefulWidget {
  final PersonDirectoryApi api;

  const PersonImportPage({super.key, this.api = const PersonDirectoryApi()});

  /// The template: the header and one example row, with a BOM so spreadsheets read
  /// Turkish letters.
  static String template() => '﻿${personImportColumns.join(';')}\n'
      'A Blok;12;3;Ayşe Yılmaz;ayse@ornek.com;0532 123 45 67;24;1.250,00;evet;;;\n';

  @override
  State<PersonImportPage> createState() => _PersonImportPageState();
}

class _PersonImportPageState extends State<PersonImportPage> {
  final _text = TextEditingController();
  ImportReport? _report;
  String? _checkedText;
  String? _fileName;
  bool _busy = false;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  bool get _canCommit =>
      !_busy && _report != null && _report!.dryRun && _report!.invalid == 0 && _checkedText == _text.text;

  void _downloadTemplate() {
    final saved = downloadBytes('kisi_sablonu.csv', utf8.encode(PersonImportPage.template()), 'text/csv');
    ScaffoldMessenger.of(context).showSnackBar(spSnackBar(
      kind: saved ? ToastKind.success : ToastKind.warning,
      content: Text(saved ? 'Şablon indirildi.' : 'Bu cihazda dosya indirme desteklenmiyor; sütunları aşağıdan kopyalayın.'),
    ));
  }

  Future<void> _pickFile() async {
    final file = await pickBankFile(accept: '.csv,.txt');
    if (file == null || !mounted) return;
    setState(() {
      _fileName = file.name;
      _text.text = utf8.decode(file.bytes, allowMalformed: true);
      _report = null;
    });
  }

  Future<void> _run({required bool dryRun}) async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final text = _text.text;
    setState(() => _busy = true);
    try {
      final report = await widget.api.importCsv(text, dryRun: dryRun);
      if (!mounted) return;
      setState(() {
        _report = report;
        _checkedText = text;
      });
      if (!dryRun && report.committed) {
        messenger.showSnackBar(spSnackBar(
          kind: ToastKind.success,
          content: Text('${report.created} kayıt eklendi; etkinleştirme bağlantıları gönderildi.'),
        ));
        if (report.invalid == 0) navigator.pop(true);
      }
    } on ApiException catch (e) {
      messenger.showSnackBar(spSnackBar(kind: ToastKind.error, content: Text(e.message)));
    } catch (_) {
      messenger.showSnackBar(spSnackBar(kind: ToastKind.error, content: const Text('Dosya gönderilemedi. Tekrar deneyin.')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final report = _report;
    return AppFullscreenPage(
      title: 'Kişileri içe aktar',
      subtitle: 'CSV dosyasından malik ve kiracı kaydı',
      icon: const Icon(Icons.upload_file_outlined),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SpGuidanceCard(
            icon: Icons.checklist_rounded,
            title: 'Nasıl çalışır?',
            message: '1. Şablonu indirip doldurun (sütun adlarını değiştirmeyin).\n'
                '2. Dosyayı seçin veya içeriği yapıştırın.\n'
                '3. "Kontrol et" hiçbir şeyi kaydetmez, her satırın hatasını gösterir.\n'
                '4. Hata kalmadığında "İçe aktar" tüm satırları kaydeder ve etkinleştirme bağlantılarını gönderir.',
          ),
          const SizedBox(height: AppSpacing.md),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: [
              testId('person_import_template_btn', OutlinedButton.icon(
                key: const Key('person_import_template_btn'),
                onPressed: _downloadTemplate,
                icon: const Icon(Icons.download_outlined, size: 16),
                label: const Text('Şablonu indir'),
              )),
              testId('person_import_pick_btn', OutlinedButton.icon(
                key: const Key('person_import_pick_btn'),
                onPressed: _busy ? null : _pickFile,
                icon: const Icon(Icons.attach_file, size: 16),
                label: Text(_fileName ?? 'Dosya seç'),
              ), label: _fileName == null ? 'CSV dosyası seç' : 'Seçilen dosya: $_fileName'),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          testId('person_import_text', TextField(
            key: const Key('person_import_text'),
            controller: _text,
            minLines: 4,
            maxLines: 10,
            onChanged: (_) => setState(() {}),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
            decoration: InputDecoration(
              labelText: 'CSV içeriği',
              helperText: 'Sütunlar: ${personImportColumns.join(', ')}',
              helperMaxLines: 3,
              alignLabelWithHint: true,
            ),
          )),
          const SizedBox(height: AppSpacing.md),
          Row(
            children: [
              Expanded(
                child: testId('person_import_check_btn', OutlinedButton(
                  key: const Key('person_import_check_btn'),
                  onPressed: _busy || _text.text.trim().isEmpty ? null : () => _run(dryRun: true),
                  child: Text(_busy ? 'Gönderiliyor…' : 'Kontrol et'),
                )),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: testId('person_import_commit_btn', FilledButton(
                  key: const Key('person_import_commit_btn'),
                  onPressed: _canCommit ? () => _run(dryRun: false) : null,
                  child: Text(report != null && report.dryRun && report.invalid == 0
                      ? 'İçe aktar (${report.total} kayıt)'
                      : 'İçe aktar'),
                ), label: 'İçe aktar; önce kontrol edilmeli'),
              ),
            ],
          ),
          if (report != null) ...[
            const SizedBox(height: AppSpacing.lg),
            _summary(report),
            const SizedBox(height: AppSpacing.sm),
            for (final row in report.rows)
              if (!row.ok || row.warnings.isNotEmpty || report.committed) _RowResult(row: row),
          ],
        ],
      ),
    );
  }

  Widget _summary(ImportReport report) {
    if (report.committed) {
      return SpGuidanceCard(
        icon: Icons.task_alt,
        title: '${report.created} / ${report.total} kayıt eklendi',
        message: report.invalid == 0
            ? 'Tüm satırlar kaydedildi.'
            : '${report.invalid} satır kayıt sırasında reddedildi; aşağıda nedenleri var.',
        tone: report.invalid == 0 ? SpTone.success : SpTone.warning,
      );
    }
    if (report.invalid > 0) {
      return SpGuidanceCard(
        icon: Icons.error_outline,
        title: '${report.invalid} satırda hata var',
        message: 'Hiçbir kayıt yapılmadı. Hataları düzeltip yeniden kontrol edin.',
        tone: SpTone.danger,
      );
    }
    return SpGuidanceCard(
      icon: Icons.fact_check_outlined,
      title: '${report.total} satır kaydedilmeye hazır',
      message: _checkedText == _text.text
          ? 'Kontrol tamam. "İçe aktar" ile kaydedin.'
          : 'İçerik değişti; yeniden kontrol edin.',
      tone: SpTone.success,
    );
  }
}

class _RowResult extends StatelessWidget {
  final ImportRowResult row;

  const _RowResult({required this.row});

  @override
  Widget build(BuildContext context) {
    final tone = !row.ok ? SpTone.danger : (row.warnings.isNotEmpty ? SpTone.warning : SpTone.success);
    final where = [row.block, if (row.unitNo != null) 'Daire ${row.unitNo}'].where((v) => v.isNotEmpty).join(' • ');
    final lines = [...row.errors, ...row.warnings];
    return Semantics(
      container: true,
      label: '${row.line}. satır, $where, ${row.ownerName}, '
          '${row.ok ? 'hata yok' : '${row.errors.length} hata'}',
      child: ExcludeSemantics(
        child: testId('person_import_row_${row.line}', ListTile(
          key: Key('person_import_row_${row.line}'),
          contentPadding: EdgeInsets.zero,
          leading: SpStatusBadge(label: '${row.line}. satır', tone: tone),
          title: Text([where, row.ownerName].where((v) => v.isNotEmpty).join(' — ')),
          subtitle: lines.isEmpty
              ? Text(row.activation == 'SENT' ? 'Kaydedildi, bağlantı gönderildi.' : 'Kaydedildi.')
              : Text(lines.join('\n')),
        )),
      ),
    );
  }
}
