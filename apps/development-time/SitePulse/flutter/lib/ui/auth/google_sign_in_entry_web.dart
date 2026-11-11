import 'package:flutter/material.dart';
import 'package:google_sign_in_web/web_only.dart' as google_web;

import '../dashboard/dashboard_controller.dart';
import '../design_system/brand_marks.dart';

Widget buildGoogleSignInEntry(DashboardController controller) =>
    FutureBuilder<void>(
      future: controller.prepareGoogleSignIn(),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: null,
              icon: const GoogleMark(size: 18),
              label: const Text('Google ile Giriş Yap'),
            ),
          );
        }
        if (snapshot.connectionState != ConnectionState.done) {
          return const SizedBox(
            height: 40,
            child: Center(child: CircularProgressIndicator()),
          );
        }
        return google_web.renderButton(
          configuration: google_web.GSIButtonConfiguration(
            text: google_web.GSIButtonText.signinWith,
            size: google_web.GSIButtonSize.large,
            shape: google_web.GSIButtonShape.rectangular,
            minimumWidth: 360,
          ),
        );
      },
    );
