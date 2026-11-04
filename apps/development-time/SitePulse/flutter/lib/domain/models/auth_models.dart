enum UserRole {
  homeOwner('Kat Maliki (Ev Sahibi)', 'AY'),
  homeResident('Ev Sakini (Aile / Kiracı)', 'ZY'),
  siteManager('Site Yöneticisi', 'MD'),
  saasAdmin('SaaS Platform Admin', 'SA');

  final String displayName;
  final String initials;
  const UserRole(this.displayName, this.initials);
}

enum SiteAdminActivePath {
  managerCockpit('Site Yönetim Paneli', 'Tüm bloklar, aidat tahsilat tablosu ve sakin onayları'),
  myFlatOwner('Kendi Dairem (Kat Maliki)', 'B Blok D:1 yönetici dairesi aidat, makbuz ve hane yönetimi');

  final String title;
  final String description;
  const SiteAdminActivePath(this.title, this.description);
}

enum AuthProvider {
  local('Şifre ile Giriş', '🔑'),
  google('Google Hesabı', '🌐'),
  hybrid('Şifre & Google', '⚡');

  final String label;
  final String iconLabel;
  const AuthProvider(this.label, this.iconLabel);
}

class PermissionScope {
  final String code;
  final String title;
  final bool isGranted;
  final String isolationNote;

  const PermissionScope({
    required this.code,
    required this.title,
    required this.isGranted,
    required this.isolationNote,
  });
}

class UserSession {
  final String id;
  final String fullName;
  final String email;
  final String phone;
  final UserRole role;
  final String siteName;
  final String unitName;
  final AuthProvider authProvider;
  final String? avatarUrl;
  final List<PermissionScope> permissions;
  final bool mustChangePassword;

  const UserSession({
    required this.id,
    required this.fullName,
    required this.email,
    required this.phone,
    required this.role,
    required this.siteName,
    required this.unitName,
    required this.authProvider,
    this.avatarUrl,
    required this.permissions,
    this.mustChangePassword = false,
  });

  UserSession copyWith({
    String? id,
    String? fullName,
    String? email,
    String? phone,
    UserRole? role,
    String? siteName,
    String? unitName,
    AuthProvider? authProvider,
    String? avatarUrl,
    List<PermissionScope>? permissions,
    bool? mustChangePassword,
  }) {
    return UserSession(
      id: id ?? this.id,
      fullName: fullName ?? this.fullName,
      email: email ?? this.email,
      phone: phone ?? this.phone,
      role: role ?? this.role,
      siteName: siteName ?? this.siteName,
      unitName: unitName ?? this.unitName,
      authProvider: authProvider ?? this.authProvider,
      avatarUrl: avatarUrl ?? this.avatarUrl,
      permissions: permissions ?? this.permissions,
      mustChangePassword: mustChangePassword ?? this.mustChangePassword,
    );
  }
}
