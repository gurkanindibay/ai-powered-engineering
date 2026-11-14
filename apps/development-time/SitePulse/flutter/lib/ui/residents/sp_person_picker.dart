import 'dart:async';

import 'package:flutter/material.dart';

import '../../domain/models/person_ref.dart';
import '../../domain/repositories/person_repository.dart';
import '../../domain/services/person_directory_api.dart';
import '../../testing/test_id.dart';
import '../components/app_fullscreen_page.dart';
import '../design_system/sp_guidance_card.dart';
import 'sp_person_card.dart';
import 'sp_person_form.dart';

/// Opens the full-screen person search and returns an existing card reference.
Future<PersonRef?> showSpPersonPicker({
  required BuildContext context,
  required PersonRepository repository,
  String? roleContext,
  String? unitId,
  String initialQuery = '',
}) => AppFullscreenPage.push<PersonRef>(
  context: context,
  builder: (_) => _SpPersonPickerPage(
    repository: repository,
    roleContext: roleContext,
    unitId: unitId,
    initialQuery: initialQuery,
  ),
);

class _SpPersonPickerPage extends StatefulWidget {
  final PersonRepository repository;
  final String? roleContext;
  final String? unitId;
  final String initialQuery;

  const _SpPersonPickerPage({
    required this.repository,
    this.roleContext,
    this.unitId,
    required this.initialQuery,
  });

  @override
  State<_SpPersonPickerPage> createState() => _SpPersonPickerPageState();
}

class _SpPersonPickerPageState extends State<_SpPersonPickerPage> {
  late final TextEditingController _search;
  Timer? _debounce;
  List<PersonSearchResult> _items = [];
  int _total = 0;
  int _page = 0;
  int _request = 0;
  bool _loading = false;
  bool _hasError = false;

  @override
  void initState() {
    super.initState();
    _search = TextEditingController(text: widget.initialQuery);
    _load(reset: true);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  void _onQueryChanged(String _) {
    _debounce?.cancel();
    _debounce = Timer(
      const Duration(milliseconds: 300),
      () => _load(reset: true),
    );
  }

  Future<void> _load({required bool reset}) async {
    final request = ++_request;
    final targetPage = reset ? 1 : _page + 1;
    setState(() {
      _loading = true;
      _hasError = false;
    });
    try {
      final result = await widget.repository.search(
        query: _search.text.trim(),
        context: widget.roleContext,
        unitId: widget.unitId,
        page: targetPage,
        pageSize: 50,
      );
      if (!mounted || request != _request) return;
      setState(() {
        _items = reset ? result.items : [..._items, ...result.items];
        _page = result.page;
        _total = result.total;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || request != _request) return;
      setState(() {
        _loading = false;
        _hasError = true;
      });
    }
  }

  Future<void> _create() async {
    final person = await AppFullscreenPage.push<PersonSummary>(
      context: context,
      builder: (_) => SpPersonForm(
        repository: widget.repository,
        initialQuery: _search.text,
      ),
    );
    if (!mounted || person == null) return;
    Navigator.pop(context, PersonRef.existing(person.personId));
  }

  void _select(PersonSearchResult result) {
    if (!result.allowed) return;
    Navigator.pop(context, widget.repository.referenceFor(result));
  }

  @override
  Widget build(BuildContext context) => AppFullscreenPage(
    title: 'Kişi seç',
    subtitle: 'İşlem için uygun olmayan kişiler de nedenleriyle gösterilir.',
    bottomBar: AppFullscreenPage.buildBottomBar(
      context: context,
      children: [
        OutlinedButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Geri dön'),
        ),
      ],
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        testId(
          'sp_person_search',
          TextField(
            key: const Key('sp_person_search'),
            controller: _search,
            onChanged: _onQueryChanged,
            autofocus: true,
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              labelText: 'Ad, telefon, e-posta veya daire ara',
            ),
          ),
        ),
        const SizedBox(height: 8),
        testId(
          'sp_person_create',
          OutlinedButton.icon(
            key: const Key('sp_person_create'),
            onPressed: _create,
            icon: const Icon(Icons.person_add_alt_1),
            label: const Text('Yeni kişi oluştur'),
          ),
        ),
        const SizedBox(height: 12),
        if (_hasError)
          SpGuidanceCard(
            icon: Icons.cloud_off_outlined,
            title: 'Kişiler yüklenemedi',
            message: 'Bağlantıyı kontrol edip tekrar deneyin.',
            action: TextButton(
              onPressed: () => _load(reset: true),
              child: const Text('Tekrar dene'),
            ),
          ),
        if (!_loading && !_hasError && _items.isEmpty)
          const SpGuidanceCard(
            icon: Icons.person_search_outlined,
            title: 'Kişi bulunamadı',
            message: 'Aramayı değiştirin veya yeni kişi oluşturun.',
          ),
        for (final result in _items)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Opacity(
              opacity: result.allowed ? 1 : 0.62,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SpPersonCard(
                    id: 'sp_person_result_${result.person.personId}',
                    person: result.person,
                    size: SpPersonCardSize.row,
                    roles: result.roles,
                    unitLabels: result.unitLabels,
                    onTap: result.allowed ? () => _select(result) : null,
                  ),
                  if (!result.allowed)
                    Padding(
                      padding: const EdgeInsets.only(left: 12, top: 4),
                      child: Text(
                        result.eligibilityMessage,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                ],
              ),
            ),
          ),
        if (_loading)
          const Center(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: CircularProgressIndicator(
                semanticsLabel: 'Kişiler yükleniyor',
              ),
            ),
          ),
        if (!_loading && _page * 50 < _total)
          testId(
            'sp_person_load_more',
            OutlinedButton(
              key: const Key('sp_person_load_more'),
              onPressed: () => _load(reset: false),
              child: Text('Daha fazla göster (${_items.length}/$_total)'),
            ),
          ),
      ],
    ),
  );
}
