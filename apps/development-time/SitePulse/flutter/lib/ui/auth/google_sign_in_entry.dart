import 'package:flutter/widgets.dart';

import '../dashboard/dashboard_controller.dart';
import 'google_sign_in_entry_stub.dart'
    if (dart.library.js_interop) 'google_sign_in_entry_web.dart'
    as platform;

Widget buildGoogleSignInEntry(DashboardController controller) {
  return platform.buildGoogleSignInEntry(controller);
}
