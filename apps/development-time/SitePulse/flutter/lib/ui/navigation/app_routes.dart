import '../../domain/models/auth_models.dart';
import '../dashboard/dashboard_controller.dart';

/// One URL per role and tab, so browser back, reload and bookmarks work on web.
///
/// | Who                         | Tabs (index → path)                                     |
/// | --------------------------- | ------------------------------------------------------- |
/// | Homeowner / resident        | 0 `/resident/home`, 1 `/resident/unit`                  |
/// | Site manager (cockpit)      | 0 `/manager/home`, 1 `/manager/dues`, 2 `/manager/residents` |
/// | Site manager (own flat)     | 0 `/manager/my-flat/home`, 1 `/manager/my-flat/unit`    |
/// | SaaS admin                  | 0 `/admin/home`, 1 `/admin/sites`                       |
/// | Auditor (denetçi)           | 0 `/auditor/home`                                       |
///
/// Signed-out users are always on `/login`.
class AppRoutes {
  const AppRoutes._();

  static const login = '/login';

  /// Tab path segments for the role/path the controller is in now.
  static List<String> tabSegments(DashboardController controller) {
    switch (controller.userRole) {
      case UserRole.siteManager:
        return controller.siteAdminPath == SiteAdminActivePath.managerCockpit
            ? const ['home', 'dues', 'residents']
            : const ['home', 'unit'];
      case UserRole.saasAdmin:
        return const ['home', 'sites'];
      case UserRole.auditor:
        return const ['home'];
      case UserRole.homeOwner:
      case UserRole.homeResident:
        return const ['home', 'unit'];
    }
  }

  static String _prefix(DashboardController controller) {
    switch (controller.userRole) {
      case UserRole.siteManager:
        return controller.siteAdminPath == SiteAdminActivePath.managerCockpit ? '/manager' : '/manager/my-flat';
      case UserRole.saasAdmin:
        return '/admin';
      case UserRole.auditor:
        return '/auditor';
      case UserRole.homeOwner:
      case UserRole.homeResident:
        return '/resident';
    }
  }

  /// The URL for [tab] of the signed-in user.
  static Uri pathFor(DashboardController controller, int tab) {
    if (!controller.isAuthenticated) return Uri(path: login);
    final segments = tabSegments(controller);
    final safe = tab >= 0 && tab < segments.length ? tab : 0;
    return Uri(path: '${_prefix(controller)}/${segments[safe]}');
  }

  /// Resolves [uri] for the signed-in user: applies the manager path it names
  /// and returns the tab index, or null when the URL belongs to another role.
  static int? resolve(DashboardController controller, Uri uri) {
    final parts = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    if (parts.isEmpty) return 0;
    final role = controller.userRole;
    String? tabName;
    switch (parts.first) {
      case 'resident':
        if (role != UserRole.homeOwner && role != UserRole.homeResident) return null;
        tabName = parts.length > 1 ? parts[1] : 'home';
      case 'auditor':
        if (role != UserRole.auditor) return null;
        tabName = 'home';
      case 'admin':
        if (role != UserRole.saasAdmin) return null;
        tabName = parts.length > 1 ? parts[1] : 'home';
      case 'manager':
        if (role != UserRole.siteManager) return null;
        final ownFlat = parts.length > 1 && parts[1] == 'my-flat';
        final wanted = ownFlat ? SiteAdminActivePath.myFlatOwner : SiteAdminActivePath.managerCockpit;
        if (controller.siteAdminPath != wanted) controller.setSiteAdminPath(wanted);
        final rest = parts.skip(ownFlat ? 2 : 1).toList();
        tabName = rest.isEmpty ? 'home' : rest.first;
      default:
        return null;
    }
    final index = tabSegments(controller).indexOf(tabName);
    return index < 0 ? 0 : index;
  }
}
