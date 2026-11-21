import 'package:flutter/material.dart';

import '../design_system/sp_tone.dart';
import '../theme/app_theme.dart';
import '../../testing/test_id.dart';

/// Shared directory layout with a scrollable header, lazy rows and local paging.
///
/// Callers own search, filters and sorting so the same scaffold can serve
/// people, units and other site directories without hiding their domain rules.
class SpDirectoryScaffold<T> extends StatefulWidget {
  final List<T> items;
  final Widget header;
  final Widget emptyState;
  final Widget Function(BuildContext context, T item, int index) itemBuilder;
  final int initialPageSize;
  final String restorationId;
  final Object? resultKey;
  final String? resultLabel;
  final int? totalItems;
  final int pageIndex;
  final int pageSize;
  final bool loading;
  final void Function(int pageIndex, int pageSize)? onPageChanged;

  const SpDirectoryScaffold({
    super.key,
    required this.items,
    required this.header,
    required this.emptyState,
    required this.itemBuilder,
    required this.restorationId,
    this.initialPageSize = 25,
    this.resultLabel,
    this.resultKey,
    this.totalItems,
    this.pageIndex = 0,
    this.pageSize = 25,
    this.loading = false,
    this.onPageChanged,
  });

  @override
  State<SpDirectoryScaffold<T>> createState() => _SpDirectoryScaffoldState<T>();
}

class _SpDirectoryScaffoldState<T> extends State<SpDirectoryScaffold<T>>
    with RestorationMixin {
  final RestorableInt _page = RestorableInt(0);
  late final RestorableInt _pageSize;
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _pageSize = RestorableInt(widget.initialPageSize);
  }

  @override
  String? get restorationId => widget.restorationId;

  @override
  void restoreState(RestorationBucket? oldBucket, bool _) {
    if (widget.onPageChanged == null) {
      registerForRestoration(_page, 'page');
      registerForRestoration(_pageSize, 'pageSize');
      _clampPage();
    }
  }

  @override
  void didUpdateWidget(covariant SpDirectoryScaffold<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.onPageChanged != null) {
      if (oldWidget.resultKey != widget.resultKey &&
          _scrollController.hasClients) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _scrollController.hasClients) {
            _scrollController.jumpTo(0);
          }
        });
      }
      return;
    }
    if (oldWidget.resultKey != widget.resultKey) {
      _page.value = 0;
      if (_scrollController.hasClients) _scrollController.jumpTo(0);
    } else if (oldWidget.items.length != widget.items.length) {
      _clampPage();
    }
  }

  void _clampPage() {
    final maxPage = widget.items.isEmpty
        ? 0
        : (widget.items.length - 1) ~/ _pageSize.value;
    if (_page.value > maxPage) _page.value = maxPage;
  }

  void _changePageSize(int pageSize) {
    if (widget.onPageChanged case final onChanged?) {
      if (_scrollController.hasClients) _scrollController.jumpTo(0);
      onChanged(0, pageSize);
      return;
    }
    setState(() {
      _pageSize.value = pageSize;
      _page.value = 0;
    });
    if (_scrollController.hasClients) _scrollController.jumpTo(0);
  }

  void _changePage(int page) {
    if (widget.onPageChanged case final onChanged?) {
      if (_scrollController.hasClients) _scrollController.jumpTo(0);
      onChanged(page, widget.pageSize);
      return;
    }
    setState(() => _page.value = page);
    if (_scrollController.hasClients) _scrollController.jumpTo(0);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    if (widget.onPageChanged == null) {
      unregisterFromRestoration(_page);
      unregisterFromRestoration(_pageSize);
    }
    _page.dispose();
    _pageSize.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final externallyPaged = widget.onPageChanged != null;
    final total = widget.totalItems ?? widget.items.length;
    final page = externallyPaged ? widget.pageIndex : _page.value;
    final pageSize = externallyPaged ? widget.pageSize : _pageSize.value;
    final start = total == 0 ? 0 : page * pageSize;
    final end = (start + (externallyPaged ? widget.items.length : pageSize))
        .clamp(0, total);
    final pageItems = externallyPaged
        ? widget.items
        : widget.items.sublist(start, end);
    final pageCount = total == 0 ? 0 : (total + pageSize - 1) ~/ pageSize;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        widget.header,
        const SizedBox(height: AppSpacing.md),
        Expanded(
          child: total == 0
              ? Center(
                  child: widget.loading
                      ? const CircularProgressIndicator(
                          semanticsLabel: 'Yükleniyor',
                        )
                      : SingleChildScrollView(child: widget.emptyState),
                )
              : ListView.builder(
                  key: PageStorageKey<String>('${widget.restorationId}-rows'),
                  restorationId: '${widget.restorationId}_rows',
                  controller: _scrollController,
                  itemCount: pageItems.length,
                  itemBuilder: (context, index) => Padding(
                    padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                    child: widget.itemBuilder(
                      context,
                      pageItems[index],
                      start + index,
                    ),
                  ),
                ),
        ),
        const SizedBox(height: AppSpacing.sm),
        _DirectoryPager(
          start: total == 0 ? 0 : start + 1,
          end: end,
          total: total,
          page: page,
          pageCount: pageCount,
          pageSize: pageSize,
          resultLabel: widget.resultLabel,
          onPageSizeChanged: _changePageSize,
          onPageChanged: _changePage,
        ),
      ],
    );
  }
}

class _DirectoryPager extends StatelessWidget {
  final int start;
  final int end;
  final int total;
  final int page;
  final int pageCount;
  final int pageSize;
  final String? resultLabel;
  final ValueChanged<int> onPageSizeChanged;
  final ValueChanged<int> onPageChanged;

  const _DirectoryPager({
    required this.start,
    required this.end,
    required this.total,
    required this.page,
    required this.pageCount,
    required this.pageSize,
    required this.resultLabel,
    required this.onPageSizeChanged,
    required this.onPageChanged,
  });

  @override
  Widget build(BuildContext context) {
    final label = resultLabel == null
        ? '$start–$end / $total'
        : '$start–$end / $total ${resultLabel!}';
    return LayoutBuilder(
      builder: (context, constraints) {
        final narrow = constraints.maxWidth < 520;
        final count = Text(label, style: Theme.of(context).textTheme.bodySmall);
        final size = DropdownButton<int>(
          value: pageSize,
          isDense: true,
          underline: const SizedBox.shrink(),
          items: const [25, 50, 100]
              .map(
                (value) => DropdownMenuItem(
                  value: value,
                  child: Text('$value / sayfa'),
                ),
              )
              .toList(),
          onChanged: (value) {
            if (value != null) onPageSizeChanged(value);
          },
        );
        final previous = testId(
          'directory_previous_page_btn',
          IconButton(
            tooltip: 'Önceki sayfa',
            onPressed: page > 0 ? () => onPageChanged(page - 1) : null,
            icon: const Icon(Icons.chevron_left),
          ),
          label: 'Önceki sayfa',
        );
        final next = testId(
          'directory_next_page_btn',
          IconButton(
            tooltip: 'Sonraki sayfa',
            onPressed: page + 1 < pageCount
                ? () => onPageChanged(page + 1)
                : null,
            icon: const Icon(Icons.chevron_right),
          ),
          label: 'Sonraki sayfa',
        );
        return DecoratedBox(
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: AppColors.border(context))),
          ),
          child: narrow
              ? Column(
                  children: [
                    Row(
                      children: [
                        Expanded(child: count),
                        size,
                      ],
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [previous, next],
                    ),
                  ],
                )
              : Row(
                  children: [
                    Expanded(child: count),
                    size,
                    const SizedBox(width: AppSpacing.sm),
                    previous,
                    Text(
                      pageCount == 0 ? '0 / 0' : '${page + 1} / $pageCount',
                      style: Theme.of(context).textTheme.bodySmall
                          ?.copyWith(color: SpTone.neutral.foreground(context)),
                    ),
                    next,
                  ],
                ),
        );
      },
    );
  }
}
