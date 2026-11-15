import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sitepulse/domain/models/person_ref.dart';
import 'package:sitepulse/domain/services/api_client.dart';
import 'package:sitepulse/ui/dashboard/dashboard_controller.dart';

void main() {
  // covers: SC-12-06-01
  test(
    'registering a unit sends person references instead of inline identity',
    () async {
      final previous = ApiClient.transport;
      Map<String, dynamic>? sent;
      ApiClient.transport = MockClient((request) async {
        if (request.method == 'POST' &&
            request.url.path.endsWith('/home-owners')) {
          sent = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(jsonEncode({'detail': 'stop'}), 422);
        }
        return http.Response('[]', 200);
      });
      final controller = DashboardController(isTestMode: true)
        ..isTestMode = false;
      await controller.registerHomeOwner(
        block: 'A',
        unitNo: 3,
        ownerRef: const PersonRef.existing(1),
        tenantRef: const PersonRef.existing(2),
        members: const [
          RegistrationMember(
            person: PersonRef.existing(3),
            relationship: 'SPOUSE',
          ),
        ],
      );
      ApiClient.transport = previous;
      controller.dispose();

      expect(sent?['owner'], {'kind': 'existing', 'person_id': 1});
      expect(sent?['tenant'], {'kind': 'existing', 'person_id': 2});
      expect((sent?['members'] as List).single['relationship'], 'SPOUSE');
      expect(sent!.containsKey('owner_full_name'), isFalse);
      expect(sent!.containsKey('tenant_full_name'), isFalse);
    },
  );
}
