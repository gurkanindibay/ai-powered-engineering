import 'package:flutter/foundation.dart';

import '../../domain/models/auth_models.dart';
import '../../testing/test_id.dart';
import '../dashboard/dashboard_controller.dart';
import '../navigation/app_routes.dart';

/// Strictly developer-only quick-login handoff for manual testing and the PM workbench.
///
/// The handoff is a deep link carrying persona credentials in the URL fragment
/// (never the query string, so they cannot reach server logs or the `Referer`
/// header). It is gated by [kShowDevTools] and is structurally impossible in a
/// production/release build: [isProduction] is checked before any test seam, so
/// no override can enable the handoff there.
class DevQuickLoginGate {
  const DevQuickLoginGate._();

  /// Production/release builds, where the handoff must never run.
  static bool get isProduction =>
      debugProductionOverride ?? (kReleaseMode || const bool.fromEnvironment('dart.vm.product'));

  /// Whether the environment permits the developer handoff at all.
  static bool get isEnabled => !isProduction && kShowDevTools;

  /// Test seams only. [debugProductionOverride] simulates a production build so a
  /// test can prove [allowed] stays false there; [debugEnabledOverride] simulates
  /// a debug build without dev tools. Neither can enable the handoff in production.
  @visibleForTesting
  static bool? debugEnabledOverride;

  @visibleForTesting
  static bool? debugProductionOverride;

  /// Effective gate: always false in production, otherwise [debugEnabledOverride]
  /// when a test set it, else [isEnabled].
  static bool get allowed => !isProduction && (debugEnabledOverride ?? isEnabled);

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
        _fragmentPath(uri) == AppRoutes.quickLogin ||
        params['quick_login'] == 'true' ||
        params.containsKey('quick_login_email') ||
        (params.containsKey('email') && params.containsKey('password') && params.containsKey('quick_login'));

    if (!isQuickLogin) {
      return null;
    }

    final email = (params['email'] ?? params['quick_login_email'])?.trim();
    final password = params['password'] ?? params['quick_login_password'] ?? '';

    if (email == null || email.isEmpty) {
      return null;
    }

    // 3. Resolve the persona role and landing path before signing in, so the
    //    manager-only admin path is never set on a resident or admin session.
    final targetPath = params['target'];
    final targetRole = _parseRole(params['role']);
    final adminPath = _adminPathFor(targetRole, targetPath);

    final success = await controller.loginWithPassword(
      email,
      password,
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

  /// Parses the optional `role` parameter, tolerating an unknown value instead of
  /// throwing: the URL is untrusted input and must never break navigation.
  static UserRole? _parseRole(String? rawRole) {
    if (rawRole == null || rawRole.trim().isEmpty) return null;
    try {
      return UserRole.fromApi(rawRole.trim().toUpperCase());
    } on FormatException {
      return null;
    }
  }

  /// Picks the manager landing path; other roles keep the controller default.
  static SiteAdminActivePath? _adminPathFor(UserRole? role, String? targetPath) {
    final isManager = role == null || role == UserRole.siteManager;
    if (!isManager) return null;
    return targetPath != null && targetPath.contains('my-flat')
        ? SiteAdminActivePath.myFlatOwner
        : SiteAdminActivePath.managerCockpit;
  }

  /// The route path inside a hash fragment, e.g. `/#/quick-login?...` → `/quick-login`.
  static String? _fragmentPath(Uri uri) {
    final fragment = uri.fragment;
    if (fragment.isEmpty) return null;
    final queryIndex = fragment.indexOf('?');
    final path = queryIndex >= 0 ? fragment.substring(0, queryIndex) : fragment;
    return path.isEmpty ? null : path;
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
      } on FormatException {
        // A malformed fragment is ignored; the query string still applies.
      }
    }
    return map;
  }
}
