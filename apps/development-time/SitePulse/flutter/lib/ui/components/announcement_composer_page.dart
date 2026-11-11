import 'package:flutter/material.dart';

import '../../testing/test_id.dart';
import '../theme/app_theme.dart';
import 'app_fullscreen_page.dart';

class AnnouncementComposerPage extends StatefulWidget {
  final Future<bool> Function(String title, String body) onSubmit;

  const AnnouncementComposerPage({super.key, required this.onSubmit});

  @override
  State<AnnouncementComposerPage> createState() =>
      _AnnouncementComposerPageState();
}

class _AnnouncementComposerPageState extends State<AnnouncementComposerPage> {
  final _formKey = GlobalKey<FormState>();
  final _titleController = TextEditingController();
  final _bodyController = TextEditingController();
  bool _isSubmitting = false;

  @override
  void dispose() {
    _titleController.dispose();
    _bodyController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_isSubmitting || !(_formKey.currentState?.validate() ?? false)) return;
    setState(() => _isSubmitting = true);
    final created = await widget.onSubmit(
      _titleController.text,
      _bodyController.text,
    );
    if (!mounted) return;
    if (created) {
      Navigator.pop(context);
    } else {
      setState(() => _isSubmitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppFullscreenPage(
      title: 'Site Duyurusu Yayınla',
      subtitle: 'Duyuru, bu sitedeki sakinlerin ekranında gösterilir.',
      icon: const Icon(Icons.campaign_outlined, color: AppColors.accentCyan),
      bottomBar: AppFullscreenPage.buildBottomBar(
        context: context,
        children: [
          SizedBox(
            width: double.infinity,
            child: testId(
              'btn_save_announcement',
              ElevatedButton.icon(
                onPressed: _isSubmitting ? null : _submit,
                icon: _isSubmitting
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.send_outlined),
                label: const Text('Duyuruyu Yayınla'),
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
            testId(
              'announcement_title_field',
              TextFormField(
                controller: _titleController,
                maxLength: 120,
                decoration: const InputDecoration(labelText: 'Başlık'),
                validator: (value) => value == null || value.trim().isEmpty
                    ? 'Başlık zorunludur.'
                    : null,
              ),
            ),
            const SizedBox(height: 16),
            testId(
              'announcement_body_field',
              TextFormField(
                controller: _bodyController,
                minLines: 4,
                maxLines: 8,
                maxLength: 2000,
                decoration: const InputDecoration(
                  labelText: 'Duyuru',
                  alignLabelWithHint: true,
                ),
                validator: (value) => value == null || value.trim().isEmpty
                    ? 'Duyuru metni zorunludur.'
                    : null,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
