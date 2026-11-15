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
import 'person_import_page.dart';
import 'person_profile_page.dart';
import 'sp_directory_scaffold.dart';

/// The site's people (person module U3/U4/U8/F8): search, role and activation
/// filters, paging, the person profile and an audited CSV export.
class PeopleDirectoryPage extends StatefulWidget {
  final PersonDirectoryApi api;

  /// Cross-navigation hooks, forwarded to the person card (see [PersonProfilePage]).
  final Future<void> Function(String unitId)? onOpenUnit;
  final Future<void> Function(PersonSummary person, String role)? onGiveRole;
  final Future<void> Function(PersonSummary person)? onChanged;

  const PeopleDirectoryPage({
    super.key,
    this.api = const PersonDirectoryApi(),
    this.onOpenUnit,
    this.onGiveRole,
    this.onChanged,
  });

  @override
  State<PeopleDirectoryPage> createState() => _PeopleDirectoryPageState();
}

class _PeopleDirectoryPageState extends State<PeopleDirectoryPage>
    with RestorationMixin {
  final RestorableTextEditingController _search =
      RestorableTextEditingController();
  final RestorableStringN _role = RestorableStringN(null);
  final RestorableStringN _login = RestorableStringN(null);
  final RestorableInt _page = RestorableInt(0);
  final RestorableInt _pageSize = RestorableInt(25);
  Timer? _debounce;
  final List<PersonSummary> _items = [];
  int _total = 0;
  bool _loading = false;
  bool _exporting = false;
  String? _error;
  int _requestId = 0;

  @override
  String? get restorationId => 'people_directory';

  @override
  void restoreState(RestorationBucket? oldBucket, bool initialRestore) {
    registerForRestoration(_search, 'query');
    registerForRestoration(_role, 'role');
    registerForRestoration(_login, 'login');
    registerForRestoration(_page, 'page');
    registerForRestoration(_pageSize, 'pageSize');
    _loadPage(_page.value, _pageSize.value);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    _role.dispose();
    _login.dispose();
    _page.dispose();
    _pageSize.dispose();
    super.dispose();
  }

  Future<void> _loadPage(
    int pageIndex,
    int pageSize, {
    bool preserveItems = false,
  }) async {
    final requestId = ++_requestId;
    _page.value = pageIndex;
    _pageSize.value = pageSize;
    setState(() {
      if (!preserveItems) {
        _items.clear();
        _total = 0;
      }
      _loading = true;
      _error = null;
    });
    try {
      final page = await widget.api.directory(
        query: _search.value.text,
        role: _role.value,
        login: _login.value,
        page: pageIndex + 1,
        pageSize: pageSize,
      );
      if (!mounted || requestId != _requestId) return;
      setState(() {
        _items
          ..clear()
          ..addAll(page.items);
        _total = page.total;
      });
    } on ApiException catch (e) {
      if (mounted && requestId == _requestId) {
        setState(() => _error = e.message);
      }
    } catch (_) {
      if (mounted && requestId == _requestId) {
        setState(() => _error = 'Sunucuya ulaşılamadı. Tekrar deneyin.');
      }
    } finally {
      if (mounted && requestId == _requestId) {
        setState(() => _loading = false);
      }
    }
  }

  void _reload({bool resetPage = true, bool preserveItems = false}) =>
      _loadPage(
        resetPage ? 0 : _page.value,
        _pageSize.value,
        preserveItems: preserveItems,
      );

  void _onSearchChanged(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), _reload);
  }

  void _setRole(String? role) {
    setState(() => _role.value = _role.value == role ? null : role);
    _reload();
  }

  void _setLogin(String? login) {
    setState(() => _login.value = _login.value == login ? null : login);
    _reload();
  }

  Future<void> _export() async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _exporting = true);
    try {
      List<int> bytes;
      try {
        bytes = await widget.api.exportCsv(
          query: _search.value.text,
          role: _role.value,
          login: _login.value,
        );
      } on ApiException catch (e) {
        if (e.code != 'STEP_UP_REQUIRED' || !mounted) rethrow;
        final verified = await showStepUpPrompt(
          context,
          reason: 'Sakin listesi kişisel veri içerir. Dışa aktarmak için şifrenizi doğrulayın; işlem denetim kaydına yazılır.',
        );
        if (!verified) return;
        bytes = await widget.api.exportCsv(
          query: _search.value.text,
          role: _role.value,
          login: _login.value,
        );
      }
      final saved = downloadBytes('sakinler.csv', bytes, 'text/csv');
      messenger.showSnackBar(
        spSnackBar(
          kind: saved ? ToastKind.success : ToastKind.warning,
          content: Text(
            saved
                ? 'Sakin listesi indirildi.'
                : 'Bu cihazda dosya indirme desteklenmiyor.',
          ),
        ),
      );
    } on ApiException catch (e) {
      messenger.showSnackBar(
        spSnackBar(kind: ToastKind.error, content: Text(e.message)),
      );
    } catch (_) {
      messenger.showSnackBar(
        spSnackBar(
          kind: ToastKind.error,
          content: const Text('Dışa aktarma yapılamadı.'),
        ),
      );
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _openProfile(PersonSummary person) async {
    await AppFullscreenPage.push<void>(
      context: context,
      builder: (_) => PersonProfilePage(
        personId: person.personId,
        api: widget.api,
        onOpenUnit: widget.onOpenUnit,
        onGiveRole: widget.onGiveRole,
        onChanged: widget.onChanged,
      ),
    );
    if (mounted) _reload(resetPage: false, preserveItems: true);
  }

  Future<void> _openImport() async {
    final imported = await AppFullscreenPage.push<bool>(
      context: context,
      builder: (_) => PersonImportPage(api: widget.api),
    );
    if (imported == true && mounted) _reload();
  }

  @override
  Widget build(BuildContext context) {
    return AppFullscreenPage(
      title: 'Kişiler',
      subtitle: _loading && _items.isEmpty ? 'Yükleniyor…' : '$_total kişi',
      icon: const Icon(Icons.badge_outlined),
      isScrollable: false,
      actions: [
        testId(
          'people_import_btn',
          OutlinedButton.icon(
            key: const Key('people_import_btn'),
            onPressed: _openImport,
            icon: const Icon(Icons.upload_file_outlined, size: 16),
            label: const Text('İçe aktar'),
          ),
          label: 'Kişileri CSV dosyasından içe aktar',
        ),
        testId(
          'people_export_btn',
          OutlinedButton.icon(
            key: const Key('people_export_btn'),
            onPressed: _exporting ? null : _export,
            icon: const Icon(Icons.download_outlined, size: 16),
            label: const Text('CSV'),
          ),
          label: 'Kişi listesini dışa aktar',
        ),
      ],
      child: SpDirectoryScaffold<PersonSummary>(
        restorationId: 'people_directory_paging',
        resultKey: '${_search.value.text}|${_role.value}|${_login.value}',
        items: _items,
        totalItems: _total,
        pageIndex: _page.value,
        pageSize: _pageSize.value,
        loading: _loading,
        onPageChanged: _loadPage,
        resultLabel: 'kişi',
        emptyState: _error == null
            ? const SpGuidanceCard(
                icon: Icons.person_search_outlined,
                title: 'Kişi bulunamadı',
                message: 'Aramayı veya filtreleri değiştirin.',
              )
            : SpGuidanceCard(
                icon: Icons.cloud_off_outlined,
                title: 'Liste yüklenemedi',
                message: _error!,
                tone: SpTone.danger,
              ),
        itemBuilder: (context, person, _) =>
            _PersonRow(person: person, onTap: () => _openProfile(person)),
        header: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            testId(
              'people_search_input',
              TextField(
                key: const Key('people_search_input'),
                controller: _search.value,
                onChanged: _onSearchChanged,
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  labelText: 'Ad, e-posta veya telefon ara',
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
              children: [
                SpFilterChip(
                  id: 'people_filter_owner',
                  label: 'Malikler',
                  selected: _role.value == 'HOME_OWNER',
                  onSelected: () => _setRole('HOME_OWNER'),
                ),
                SpFilterChip(
                  id: 'people_filter_resident',
                  label: 'Sakinler',
                  selected: _role.value == 'HOME_RESIDENT',
                  onSelected: () => _setRole('HOME_RESIDENT'),
                ),
                SpFilterChip(
                  id: 'people_filter_pending',
                  label: 'Etkinleştirme bekleyen',
                  selected: _login.value == 'PENDING',
                  tone: SpTone.warning,
                  onSelected: () => _setLogin('PENDING'),
                ),
                SpFilterChip(
                  id: 'people_filter_no_login',
                  label: 'Giriş hesabı yok',
                  selected: _login.value == 'NONE',
                  onSelected: () => _setLogin('NONE'),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.lg),
            if (_error != null)
              SpGuidanceCard(
                icon: Icons.cloud_off_outlined,
                title: 'Liste yüklenemedi',
                message: _error!,
                tone: SpTone.danger,
              ),
          ],
        ),
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
    return testId(
      'people_row_${person.personId}',
      ListTile(
        key: Key('people_row_${person.personId}'),
        contentPadding: EdgeInsets.zero,
        minVerticalPadding: AppSpacing.sm,
        onTap: onTap,
        title: Text(person.fullName),
        subtitle: Text(
          [person.email, person.phone].where((v) => v.isNotEmpty).join(' • '),
        ),
        trailing: Wrap(
          spacing: AppSpacing.xs,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SpStatusBadge(
              label: personRoleLabel(person.role),
              tone: SpTone.info,
            ),
            SpStatusBadge(label: person.login.label, tone: loginTone),
          ],
        ),
      ),
      label: person.fullName,
    );
  }
}
