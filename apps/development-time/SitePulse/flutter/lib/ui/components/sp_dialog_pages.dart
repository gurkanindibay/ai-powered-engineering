import 'package:flutter/material.dart';

import '../../l10n/app_strings.dart';
import '../../testing/test_id.dart';
import '../theme/app_theme.dart';
import 'app_fullscreen_page.dart';

/// Key (and automation id) of the back button on every full-screen dialog page.
const spPageBackKey = 'btn_page_back';

/// Full-screen replacements for Material's floating dialogs and bottom sheets.
///
/// The SitePulse constitution prohibits center popups (`AlertDialog`,
/// `Dialog`, `SimpleDialog`) and partial bottom sheets for interactive flows.
/// These widgets keep the familiar dialog-shaped API (title / content /
/// actions, or a free-form child) so a flow can move to a 100% viewport page
/// without rewriting its content: each page gets an app bar with a back
/// button, a width-capped scrollable body, and (for [SpAlertPage]) a sticky
/// bottom action bar built by [AppFullscreenPage.buildBottomBar].
///
/// `Navigator.pop(ctx, value)` inside the page returns `value` to the caller,
/// exactly as it did for `showDialog`.

/// Pushes a full-screen page whose [builder] returns one of [SpDialogPage],
/// [SpAlertPage] or [SpSelectionPage]. Drop-in replacement for `showDialog`.
///
/// [barrierDismissible] is accepted for call-site compatibility; on a page the
/// back button always dismisses with `null`, which callers treat as cancel.
Future<T?> showSpPage<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
}) {
  return Navigator.of(context).push<T>(
    MaterialPageRoute<T>(builder: builder, fullscreenDialog: true),
  );
}

/// Pushes free-form content (formerly shown in a modal bottom sheet) as a
/// full-screen [SpDialogPage]. Drop-in replacement for `showModalBottomSheet`.
Future<T?> showSpSheetPage<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  String? title,
  Color? backgroundColor,
}) {
  return showSpPage<T>(
    context: context,
    builder: (ctx) => SpDialogPage(
      title: title,
      backgroundColor: backgroundColor,
      child: builder(ctx),
    ),
  );
}

AppBar _spAppBar(BuildContext context, {Widget? title}) {
  return AppBar(
    backgroundColor: AppColors.surface(context),
    surfaceTintColor: Colors.transparent,
    elevation: 0,
    centerTitle: false,
    automaticallyImplyLeading: false,
    leading: testId(spPageBackKey, IconButton(
      key: const Key(spPageBackKey),
      icon: Icon(Icons.arrow_back_ios_new_rounded, color: AppColors.textPrimary(context), size: 20),
      tooltip: AppStrings.back,
      onPressed: () => Navigator.maybePop(context),
    )),
    title: title == null
        ? null
        : DefaultTextStyle.merge(
            style: Theme.of(context).textTheme.titleMedium!.copyWith(
                  color: AppColors.textPrimary(context),
                  fontWeight: FontWeight.bold,
                ),
            child: title,
          ),
    bottom: PreferredSize(
      preferredSize: const Size.fromHeight(1),
      child: Container(color: AppColors.border(context), height: 1),
    ),
  );
}

/// Full-screen host for free-form dialog content (replaces `Dialog`).
///
/// [child] is laid out top-aligned and width-capped; content that already
/// scrolls keeps scrolling, other content is wrapped in a scroll view.
class SpDialogPage extends StatelessWidget {
  final Widget child;
  final String? title;
  final Color? backgroundColor;
  final double maxWidth;

  /// [shape] is accepted for `Dialog` call-site compatibility and ignored:
  /// a full-screen page has no floating card outline.
  const SpDialogPage({
    super.key,
    required this.child,
    this.title,
    this.backgroundColor,
    ShapeBorder? shape,
    this.maxWidth = 640,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: backgroundColor ?? AppColors.background(context),
      appBar: _spAppBar(context, title: title == null ? null : Text(title!, overflow: TextOverflow.ellipsis)),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxWidth),
            child: child,
          ),
        ),
      ),
    );
  }
}

/// Full-screen confirmation / short-form page (replaces `AlertDialog`).
///
/// [title] goes in the app bar, [content] in the scrollable body, and
/// [actions] in a sticky bottom bar (cancel left of confirm, as before).
class SpAlertPage extends StatelessWidget {
  final Widget? title;
  final Widget? content;
  final List<Widget>? actions;
  final Color? backgroundColor;
  final double maxWidth;

  /// [shape] is accepted for `AlertDialog` call-site compatibility and ignored.
  const SpAlertPage({
    super.key,
    this.title,
    this.content,
    this.actions,
    this.backgroundColor,
    ShapeBorder? shape,
    this.maxWidth = 560,
  });

  @override
  Widget build(BuildContext context) {
    final bar = actions;
    return Scaffold(
      backgroundColor: backgroundColor ?? AppColors.background(context),
      appBar: _spAppBar(context, title: title),
      bottomNavigationBar: bar == null || bar.isEmpty
          ? null
          : AppFullscreenPage.buildBottomBar(context: context, children: bar),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: maxWidth),
              child: DefaultTextStyle.merge(
                style: Theme.of(context).textTheme.bodyMedium!.copyWith(
                      color: AppColors.textPrimary(context),
                      height: 1.5,
                    ),
                child: content ?? const SizedBox.shrink(),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Full-screen single-choice list (replaces `SimpleDialog`).
class SpSelectionPage extends StatelessWidget {
  final Widget? title;
  final List<Widget> children;

  const SpSelectionPage({super.key, this.title, required this.children});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background(context),
      appBar: _spAppBar(context, title: title),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: children.length,
              separatorBuilder: (_, _) => Divider(height: 1, color: AppColors.border(context)),
              itemBuilder: (_, i) => DefaultTextStyle.merge(
                style: Theme.of(context).textTheme.bodyLarge!.copyWith(color: AppColors.textPrimary(context)),
                child: children[i],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Opens a full-screen single-choice list and returns the chosen option, or
/// `null` when the user goes back without choosing (callers must treat `null`
/// as "no change").
///
/// The [selected] option is marked with a check icon and announced as
/// selected. [idOf] supplies stable automation ids (also used as keys).
Future<T?> showSpSelection<T>({
  required BuildContext context,
  required String title,
  required List<T> options,
  required String Function(T option) labelOf,
  T? selected,
  String Function(T option)? idOf,
}) {
  return showSpPage<T>(
    context: context,
    builder: (ctx) => SpSelectionPage(
      title: Text(title),
      children: options.map((option) {
        final isSelected = option == selected;
        final id = idOf?.call(option);
        final tile = Semantics(
          selected: isSelected,
          inMutuallyExclusiveGroup: true,
          child: ListTile(
            key: id == null ? null : Key(id),
            title: Text(labelOf(option)),
            trailing: isSelected ? Icon(Icons.check_rounded, color: AppColors.primaryText(ctx)) : null,
            onTap: () => Navigator.pop(ctx, option),
          ),
        );
        return id == null ? tile : testId(id, tile);
      }).toList(),
    ),
  );
}

/// Key (and automation id) of the text field and submit button of [showSpTextPrompt].
const spPromptFieldKey = 'field_sp_prompt';
const spPromptSubmitKey = 'btn_sp_prompt_submit';

/// Opens a full-screen page that asks for one line or paragraph of text (a
/// reason, a note, a decision text) and returns it trimmed, or `null` when the
/// user goes back. Submitting is disabled until [minLength] characters are typed.
Future<String?> showSpTextPrompt({
  required BuildContext context,
  required String title,
  required String label,
  String? message,
  String submitLabel = 'Gönder',
  int minLength = 3,
  int maxLines = 4,
  String? initialValue,
}) {
  return showSpPage<String>(
    context: context,
    builder: (ctx) => SpTextPromptPage(
      title: title,
      label: label,
      message: message,
      submitLabel: submitLabel,
      minLength: minLength,
      maxLines: maxLines,
      initialValue: initialValue,
    ),
  );
}

class SpTextPromptPage extends StatefulWidget {
  final String title;
  final String label;
  final String? message;
  final String submitLabel;
  final int minLength;
  final int maxLines;
  final String? initialValue;

  const SpTextPromptPage({
    super.key,
    required this.title,
    required this.label,
    this.message,
    this.submitLabel = 'Gönder',
    this.minLength = 3,
    this.maxLines = 4,
    this.initialValue,
  });

  @override
  State<SpTextPromptPage> createState() => _SpTextPromptPageState();
}

class _SpTextPromptPageState extends State<SpTextPromptPage> {
  late final TextEditingController _text = TextEditingController(text: widget.initialValue ?? '');

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  bool get _valid => _text.text.trim().length >= widget.minLength;

  @override
  Widget build(BuildContext context) {
    return SpDialogPage(
      title: widget.title,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.message != null) ...[
              Text(widget.message!, style: TextStyle(color: AppColors.textSecondary(context))),
              const SizedBox(height: AppSpacing.md),
            ],
            testId(spPromptFieldKey, TextField(
              key: const Key(spPromptFieldKey),
              controller: _text,
              autofocus: true,
              minLines: 1,
              maxLines: widget.maxLines,
              decoration: InputDecoration(labelText: widget.label, border: const OutlineInputBorder()),
              onChanged: (_) => setState(() {}),
            )),
            const SizedBox(height: AppSpacing.lg),
            testId(spPromptSubmitKey, FilledButton(
              key: const Key(spPromptSubmitKey),
              onPressed: _valid ? () => Navigator.pop(context, _text.text.trim()) : null,
              child: Text(widget.submitLabel),
            )),
          ],
        ),
      ),
    );
  }
}
