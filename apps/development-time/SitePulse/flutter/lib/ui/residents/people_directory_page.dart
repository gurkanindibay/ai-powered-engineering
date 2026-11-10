import 'dart:async';

import 'package:flutter/material.dart';

import '../../domain/services/api_client.dart';
import '../../domain/services/person_directory_api.dart';
import '../../domain/services/platform_env.dart';
import '../../testing/test_id.dart';
import '../components/app_fullscreen_page.dart';
import '../components/step_up_prompt.dart';
import '../design_system/sp_feedback.dart';
import '../design_system/sp_filter_chip.dart';
import '../design_system/sp_guidance_card.dart';
import '../design_system/sp_status_badge.dart';
import '../design_system/sp_tone.dart';
import '../theme/app_theme.dart';
import 'person_profile_page.dart';

/// The site's people (person module U3/U4/U8/F8): search, role and activation
/// filters, paging, the person profile and an audited CSV export.
class PeopleDirectoryPage extends StatefulWidget {
  final PersonDirectoryApi api;

  const PeopleDirectoryPage({super.key, this.api = const PersonDirectoryApi()});

  @override
  State<PeopleDirectoryPage> createState() => _PeopleDirectoryPageState();
}

class _PeopleDirectoryPageState extends State<PeopleDirectoryPage> {
  final _search = TextEditingController();
  Timer? _debounce;
  String? _role;
  String? _login;
  final List<PersonSummary> _items = [];
  int _total = 0;
  int _page = 0;
  bool _hasMore = false;
  bool _loading = false;
  bool _exporting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    _items.clear();
    _page = 0;
    await _loadMore();
  }

  Future<void> _loadMore() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await widget.api.directory(query: _search.text, role: _role, login: _login, page: _page + 1);
      if (!mounted) return;
      setState(() {
        _items.addAll(page.items);
        _total = page.total;
        _page = page.page;
        _hasMore = page.hasMore;
      });
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = 'Sunucuya ulaşılamadı. Tekrar deneyin.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _onSearchChanged(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), _reload);
  }

  void _setRole(String? role) {
    setState(() => _role = _role == role ? null : role);
    _reload();
  }

  void _setLogin(String? login) {
    setState(() => _login = _login == login ? null : login);
    _reload();
  }

  Future<void> _export() async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _exporting = true);
    try {
      List<int> bytes;
      try {
        bytes = await widget.api.exportCsv(query: _search.text, role: _role, login: _login);
      } on ApiException catch (e) {
        if (e.code != 'STEP_UP_REQUIRED' || !mounted) rethrow;
        final verified = await showStepUpPrompt(
          context,
          reason: 'Sakin listesi kişisel veri içerir. Dışa aktarmak için şifrenizi doğrulayın; işlem denetim kaydına yazılır.',
        );
        if (!verified) return;
        bytes = await widget.api.exportCsv(query: _search.text, role: _role, login: _login);
      }
      final saved = downloadBytes('sakinler.csv', bytes, 'text/csv');
      messenger.showSnackBar(spSnackBar(
        kind: saved ? ToastKind.success : ToastKind.warning,
        content: Text(saved ? 'Sakin listesi indirildi.' : 'Bu cihazda dosya indirme desteklenmiyor.'),
      ));
    } on ApiException catch (e) {
      messenger.showSnackBar(spSnackBar(kind: ToastKind.error, content: Text(e.message)));
    } catch (_) {
      messenger.showSnackBar(spSnackBar(kind: ToastKind.error, content: const Text('Dışa aktarma yapılamadı.')));
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _openProfile(PersonSummary person) async {
    await AppFullscreenPage.push<void>(
      context: context,
      builder: (_) => PersonProfilePage(personId: person.personId, api: widget.api),
    );
    if (mounted) _reload();
  }

  @override
  Widget build(BuildContext context) {
    return AppFullscreenPage(
      title: 'Kişiler',
      subtitle: _loading && _items.isEmpty ? 'Yükleniyor…' : '$_total kişi',
      icon: const Icon(Icons.badge_outlined),
      actions: [
        testId('people_export_btn', OutlinedButton.icon(
          key: const Key('people_export_btn'),
          onPressed: _exporting ? null : _export,
          icon: const Icon(Icons.download_outlined, size: 16),
          label: const Text('CSV'),
        ), label: 'Kişi listesini dışa aktar'),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          testId('people_search_input', TextField(
            key: const Key('people_search_input'),
            controller: _search,
            onChanged: _onSearchChanged,
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              labelText: 'Ad, e-posta veya telefon ara',
            ),
          )),
          const SizedBox(height: AppSpacing.md),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: [
              SpFilterChip(id: 'people_filter_owner', label: 'Malikler', selected: _role == 'HOME_OWNER', onSelected: () => _setRole('HOME_OWNER')),
              SpFilterChip(id: 'people_filter_resident', label: 'Sakinler', selected: _role == 'HOME_RESIDENT', onSelected: () => _setRole('HOME_RESIDENT')),
              SpFilterChip(
                id: 'people_filter_pending',
                label: 'Etkinleştirme bekleyen',
                selected: _login == 'PENDING',
                tone: SpTone.warning,
                onSelected: () => _setLogin('PENDING'),
              ),
              SpFilterChip(id: 'people_filter_no_login', label: 'Giriş hesabı yok', selected: _login == 'NONE', onSelected: () => _setLogin('NONE')),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          if (_error != null)
            SpGuidanceCard(icon: Icons.cloud_off_outlined, title: 'Liste yüklenemedi', message: _error!, tone: SpTone.danger),
          if (_error == null && !_loading && _items.isEmpty)
            const SpGuidanceCard(
              icon: Icons.person_search_outlined,
              title: 'Kişi bulunamadı',
              message: 'Aramayı veya filtreleri değiştirin.',
            ),
          for (final person in _items) _PersonRow(person: person, onTap: () => _openProfile(person)),
          if (_loading) const Padding(padding: EdgeInsets.all(AppSpacing.lg), child: Center(child: CircularProgressIndicator())),
          if (_hasMore && !_loading)
            testId('people_load_more_btn', TextButton(
              key: const Key('people_load_more_btn'),
              onPressed: _loadMore,
              child: Text('Daha fazla göster (${_items.length}/$_total)'),
            )),
        ],
      ),
    );
  }
}

class _PersonRow extends StatelessWidget {
  final PersonSummary person;
  final VoidCallback onTap;

  const _PersonRow({required this.person, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final loginTone = switch (person.login) {
      PersonLogin.active => SpTone.success,
      PersonLogin.pending => SpTone.warning,
      PersonLogin.none => SpTone.neutral,
    };
    return testId('people_row_${person.personId}', ListTile(
      key: Key('people_row_${person.personId}'),
      contentPadding: EdgeInsets.zero,
      minVerticalPadding: AppSpacing.sm,
      onTap: onTap,
      title: Text(person.fullName),
      subtitle: Text([person.email, person.phone].where((v) => v.isNotEmpty).join(' • ')),
      trailing: Wrap(
        spacing: AppSpacing.xs,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          SpStatusBadge(label: personRoleLabel(person.role), tone: SpTone.info),
          SpStatusBadge(label: person.login.label, tone: loginTone),
        ],
      ),
    ), label: person.fullName);
  }
}
