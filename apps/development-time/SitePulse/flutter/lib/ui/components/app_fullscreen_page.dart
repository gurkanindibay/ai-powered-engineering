import '../../testing/test_id.dart';
import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// Papara-Style Full-Screen Page Component for SitePulse.
///
/// Mandated by SitePulse UX Guidelines:
/// Mobile interactions must NOT use floating center popups or partial bottom
/// sheets that feel like popups. In line with modern fintech UX (e.g. Papara),
/// all interactions, forms, breakdowns, and flows open in a dedicated full-screen
/// page (`Scaffold`), and upon completion or dismissal return cleanly to the
/// calling screen.
class AppFullscreenPage extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget? icon;
  final Widget? leading;
  final List<Widget>? actions;
  final Widget child;
  final Widget? bottomBar;
  final double maxWidth;
  final bool resizeToAvoidBottomInset;
  final bool isScrollable;

  const AppFullscreenPage({
    super.key,
    required this.title,
    this.subtitle,
    this.icon,
    this.leading,
    this.actions,
    required this.child,
    this.bottomBar,
    this.maxWidth = 640,
    this.resizeToAvoidBottomInset = true,
    this.isScrollable = true,
  });

  /// Pushes an [AppFullscreenPage] onto the navigation stack with a smooth
  /// modal transition, returning to the caller screen upon completion.
  static Future<T?> push<T>({
    required BuildContext context,
    required WidgetBuilder builder,
  }) {
    return Navigator.push<T>(
      context,
      MaterialPageRoute<T>(
        builder: builder,
        fullscreenDialog: true,
      ),
    );
  }

  /// Builds a sticky bottom action bar tailored for Papara-style full screen pages.
  static Widget buildBottomBar({
    required BuildContext context,
    required List<Widget> children,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      decoration: BoxDecoration(
        color: AppColors.surface(context),
        border: Border(top: BorderSide(color: AppColors.border(context))),
      ),
      child: SafeArea(
        top: false,
        child: children.length == 1
            ? SizedBox(
                width: double.infinity,
                child: children.first,
              )
            : Row(
                children: [
                  for (int i = 0; i < children.length; i++) ...[
                    if (i > 0) const SizedBox(width: 12),
                    Expanded(child: children[i]),
                  ],
                ],
              ),
      ),
    );
  }

  /// Displays a full-screen confirmation page (e.g. for deletions or password resets)
  /// in Papara-style and returns true if confirmed.
  static Future<bool?> pushConfirmation({
    required BuildContext context,
    required String title,
    required String message,
    String confirmLabel = 'Onayla',
    String cancelLabel = 'Vazgeç',
    Color confirmColor = AppColors.accentRed,
    IconData icon = Icons.warning_amber_rounded,
    Color iconColor = AppColors.accentRed,
  }) {
    return push<bool>(
      context: context,
      builder: (ctx) => AppFullscreenPage(
        title: title,
        leading: IconButton(
          icon: Icon(
            Icons.arrow_back_ios_new_rounded,
            color: AppColors.textPrimary(ctx),
            size: 20,
          ),
          tooltip: 'Geri Dön',
          onPressed: () => Navigator.pop(ctx, false),
        ),
        bottomBar: Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          decoration: BoxDecoration(
            color: AppColors.surface(ctx),
            border: Border(top: BorderSide(color: AppColors.border(ctx))),
          ),
          child: SafeArea(
            top: false,
            child: Row(
              children: [
                Expanded(
                  child: testId('btn_confirmation_cancel', OutlinedButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
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
                      padding: const EdgeInsets.symmetric(vertical: 14),
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
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 20),
            Center(
              child: Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  color: iconColor.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, color: iconColor, size: 36),
              ),
            ),
            const SizedBox(height: 24),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: AppColors.surface(ctx),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: AppColors.border(ctx)),
              ),
              child: Text(
                message,
                style: TextStyle(
                  color: AppColors.textPrimary(ctx),
                  fontSize: 14,
                  height: 1.5,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background(context),
      resizeToAvoidBottomInset: resizeToAvoidBottomInset,
      appBar: AppBar(
        backgroundColor: AppColors.surface(context),
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        leading: leading ??
            IconButton(
              icon: Icon(
                Icons.arrow_back_ios_new_rounded,
                color: AppColors.textPrimary(context),
                size: 20,
              ),
              tooltip: 'Geri Dön',
              onPressed: () => Navigator.pop(context),
            ),
        title: Row(
          children: [
            if (icon != null) ...[
              icon!,
              const SizedBox(width: 10),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
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
                        fontSize: 11,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
        actions: actions,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(color: AppColors.border(context), height: 1),
        ),
      ),
      bottomNavigationBar: bottomBar,
      body: SafeArea(
        child: isScrollable
            ? SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: Center(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: maxWidth),
                    child: child,
                  ),
                ),
              )
            : Center(
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: maxWidth),
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: child,
                  ),
                ),
              ),
      ),
    );
  }
}
