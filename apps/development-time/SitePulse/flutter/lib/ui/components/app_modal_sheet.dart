import '../../testing/test_id.dart';
import 'package:flutter/material.dart';
import '../../l10n/app_strings.dart';
import '../theme/app_theme.dart';

/// Legacy modal bottom sheet container.
///
/// Superseded: the SitePulse constitution prohibits partial bottom sheets and
/// center popups for interactive flows. Use [AppFullscreenPage] or
/// `showSpPage` with `SpAlertPage` / `SpDialogPage` / `SpSelectionPage`
/// (`sp_dialog_pages.dart`). Kept only so older branches still compile.
@Deprecated('Use AppFullscreenPage or showSpPage (sp_dialog_pages.dart); bottom sheets are prohibited')
class AppModalSheet extends StatelessWidget {
  final Widget? icon;
  final String? title;
  final String? subtitle;
  final Widget child;
  final List<Widget>? actions;
  final double maxWidth;
  final double maxHeightFactor;
  final bool showCloseButton;
  final VoidCallback? onClose;

  const AppModalSheet({
    super.key,
    this.icon,
    this.title,
    this.subtitle,
    required this.child,
    this.actions,
    this.maxWidth = 540,
    this.maxHeightFactor = 0.90,
    this.showCloseButton = true,
    this.onClose,
  });

  /// Opens an [AppModalSheet] using standard modal bottom sheet physics.
  static Future<T?> show<T>({
    required BuildContext context,
    required WidgetBuilder builder,
    bool isDismissible = true,
    bool enableDrag = true,
  }) {
    return showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      isDismissible: isDismissible,
      enableDrag: enableDrag,
      backgroundColor: Colors.transparent,
      builder: builder,
    );
  }

  /// Displays a standard bottom sheet confirmation dialog.
  static Future<bool?> showConfirmation({
    required BuildContext context,
    required String title,
    required String message,
    String confirmLabel = 'Onayla',
    String cancelLabel = AppStrings.cancel,
    Color confirmColor = AppColors.accentRed,
    IconData icon = Icons.warning_amber_rounded,
    Color iconColor = AppColors.accentRed,
  }) {
    return show<bool>(
      context: context,
      builder: (ctx) => AppModalSheet(
        maxWidth: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: iconColor.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(icon, color: iconColor, size: 24),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    title,
                    style: TextStyle(
                      color: AppColors.textPrimary(ctx),
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Text(
              message,
              style: TextStyle(
                color: AppColors.textSecondary(ctx),
                fontSize: 13,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: testId('btn_confirmation_cancel', OutlinedButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      side: BorderSide(color: AppColors.border(ctx)),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    child: Text(
                      cancelLabel,
                      style: TextStyle(color: AppColors.textPrimary(ctx), fontWeight: FontWeight.w600),
                    ),
                  )),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: testId('btn_confirmation_confirm', ElevatedButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: confirmColor,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      elevation: 0,
                    ),
                    child: Text(
                      confirmLabel,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  )),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final bottomInset = mediaQuery.viewInsets.bottom;
    final maxAvailableHeight = mediaQuery.size.height * maxHeightFactor;

    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: maxWidth,
          maxHeight: maxAvailableHeight,
        ),
        child: Container(
          decoration: BoxDecoration(
            color: AppColors.surface(context),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
            border: Border(top: BorderSide(color: AppColors.border(context), width: 1)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.25),
                blurRadius: 20,
                offset: const Offset(0, -4),
              ),
            ],
          ),
          padding: EdgeInsets.only(
            top: 12,
            left: 20,
            right: 20,
            bottom: bottomInset > 0 ? bottomInset + 16 : 24,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 1. Drag Handle
              Center(
                child: Container(
                  width: 44,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 14),
                  decoration: BoxDecoration(
                    color: AppColors.border(context),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),

              // 2. Optional Header Row (Icon + Title + Subtitle + Close Button)
              if (title != null) ...[
                Row(
                  children: [
                    if (icon != null) ...[
                      icon!,
                      const SizedBox(width: 10),
                    ],
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title!,
                            style: TextStyle(
                              color: AppColors.textPrimary(context),
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                          if (subtitle != null) ...[
                            const SizedBox(height: 2),
                            Text(
                              subtitle!,
                              style: TextStyle(
                                color: AppColors.textSecondary(context),
                                fontSize: 12,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ],
                      ),
                    ),
                    if (showCloseButton)
                      IconButton(
                        tooltip: AppStrings.close,
                        icon: Icon(Icons.close, size: 20, color: AppColors.textSecondary(context)),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                        onPressed: onClose ?? () => Navigator.pop(context),
                      ),
                  ],
                ),
                const SizedBox(height: 16),
              ],

              // 3. Scrollable Child Content
              Flexible(
                child: SingleChildScrollView(
                  child: child,
                ),
              ),

              // 4. Optional Action Buttons Row
              if (actions != null && actions!.isNotEmpty) ...[
                const SizedBox(height: 18),
                Align(
                  alignment: Alignment.centerRight,
                  child: Wrap(
                    alignment: WrapAlignment.end,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 8,
                    runSpacing: 8,
                    children: actions!,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
