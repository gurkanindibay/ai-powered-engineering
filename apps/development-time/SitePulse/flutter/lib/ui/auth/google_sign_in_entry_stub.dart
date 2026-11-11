import 'package:flutter/material.dart';

import '../dashboard/dashboard_controller.dart';
import '../design_system/brand_marks.dart';

Widget buildGoogleSignInEntry(DashboardController controller) =>
    OutlinedButton.icon(
      onPressed: () => controller.loginWithGoogle(),
      icon: const GoogleMark(size: 18),
      label: const Text('Google ile Giriş Yap'),
    );
