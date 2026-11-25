import 'package:flutter/foundation.dart';

import '../../domain/models/auth_models.dart';
import '../../testing/test_id.dart';
import '../dashboard/dashboard_controller.dart';
import '../navigation/app_routes.dart';

/// Strictly developer-only quick-login handoff for manual testing and the PM workbench.
///
/// Gated by [kDebugMode] / explicit non-production flag ([kShowDevTools]),
/// and strictly disabled in production/release builds ([kReleaseMode] / `dart.vm.product`).
class DevQuickLoginGate {
  const DevQuickLoginGate._();

  /// Whether the environment permits developer quick-login handoff.
  /// Strictly false in production/release builds.
  static bool get isEnabled =>
      (kDebugMode || kE2E || const bool.fromEnvironment('SITEPULSE_DEV_TOOLS')) &&
      !kReleaseMode &&
      !const bool.fromEnvironment('dart.vm.product');

  /// For testing the release/production gate in unit tests.
  @visibleForTesting
  static bool? overrideEnabled;

  /// Effective gate: uses [overrideEnabled] when set in tests, otherwise [isEnabled].
  static bool get allowed => overrideEnabled ?? isEnabled;

  /// Attempts a developer quick-login handoff from an incoming [uri].
  ///
  /// Returns the target tab index if login succeeded, or null if not handled or rejected.
  static Future<int?> tryHandleQuickLogin({
    required Uri uri,
    required DashboardController controller,
  }) async {
    // 1. Guardrail: dev quick-login is strictly rejected in production / release builds.
    if (!allowed) {
      return null;
    }

    // 2. Extract parameters from query string and hash fragment.
    final params = _extractParams(uri);
    final isQuickLogin = uri.path == AppRoutes.quickLogin ||
        params['quick_login'] == 'true' ||
        params.containsKey('quick_login_email') ||
        (params.containsKey('email') && params.containsKey('password') && params.containsKey('quick_login'));

    if (!isQuickLogin) {
      return null;
    }

    final email = params['email'] ?? params['quick_login_email'];
    final password = params['password'] ?? params['quick_login_password'] ?? '';

    if (email == null || email.trim().isEmpty) {
      return null;
    }

    // 3. Perform login with credentials
    final targetPath = params['target'];
    SiteAdminActivePath? adminPath;
    if (targetPath != null && targetPath.contains('my-flat')) {
      adminPath = SiteAdminActivePath.myFlatOwner;
    } else {
      adminPath = SiteAdminActivePath.managerCockpit;
    }

    final roleParam = params['role'];
    final targetRole = roleParam != null ? UserRole.fromApi(roleParam) : null;

    final success = await controller.loginWithPassword(
      email.trim(),
      password.trim(),
      targetRole: targetRole,
      adminPath: adminPath,
    );

    if (!success) {
      return null;
    }

    // 4. Resolve destination tab
    if (targetPath != null && targetPath.isNotEmpty) {
      final targetUri = Uri.tryParse(targetPath);
      if (targetUri != null) {
        final resolved = AppRoutes.resolve(controller, targetUri);
        if (resolved != null) return resolved;
      }
    }

    return 0;
  }

  static Map<String, String> _extractParams(Uri uri) {
    final map = Map<String, String>.from(uri.queryParameters);
    // Parse query parameters embedded inside hash fragment e.g. /#/?quick_login=true&email=...
    if (uri.fragment.isNotEmpty && uri.fragment.contains('=')) {
      final fragmentPart = uri.fragment;
      final queryIndex = fragmentPart.indexOf('?');
      final rawQuery = queryIndex >= 0 ? fragmentPart.substring(queryIndex + 1) : fragmentPart;
      try {
        final parsed = Uri.splitQueryString(rawQuery);
        map.addAll(parsed);
      } catch (_) {}
    }
    return map;
  }
}
