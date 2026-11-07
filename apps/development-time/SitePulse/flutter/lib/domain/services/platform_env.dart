// Browser-backed preferences and connectivity, with no-op fallbacks on
// platforms where the web APIs do not exist (tests, desktop, mobile).
export 'platform_env_stub.dart'
    if (dart.library.html) 'platform_env_web.dart';
