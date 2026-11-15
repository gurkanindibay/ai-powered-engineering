import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sitepulse/domain/services/api_client.dart';
import 'package:sitepulse/domain/services/person_directory_repository.dart';

/// Request contract of the picker search: the repository sends the query
/// parameters the backend `PersonSearchParams` declares, with numeric paging
/// values the server must accept as integers.
void main() {
  late http.Client previous;

  setUp(() => previous = ApiClient.transport);
  tearDown(() => ApiClient.transport = previous);

  // covers: SC-12-05-06
  test('search sends integer page and limit with context and unit', () async {
    Uri? sent;
    ApiClient.transport = MockClient((request) async {
      sent = request.url;
      return http.Response(
        jsonEncode({
          'items': [
            {
              'card': {
                'person_id': 42,
                'full_name': 'Ayşe Yılmaz',
                'email': 'ayse@e2e.test',
                'phone': '05320000042',
                'roles': ['OWNER'],
                'unit_labels': ['A Blok D:12'],
                'login': 'NONE',
                'version': 3,
                'allowed_actions': <String>[],
              },
              'eligibility': {'allowed': true, 'code': null},
            },
          ],
          'total': 51,
          'page': 2,
          'page_size': 50,
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    });

    final page = await const PersonDirectoryRepository().search(
      query: '  ayşe ',
      context: 'owner',
      unitId: '7',
      page: 2,
    );

    expect(sent, isNotNull);
    expect(sent!.path, '/api/v1/site-admin/persons/search');
    final params = sent!.queryParameters;
    expect(params['q'], 'ayşe');
    expect(params['context'], 'owner');
    expect(params['unit_id'], '7');
    expect(int.tryParse(params['page'] ?? ''), 2);
    expect(int.tryParse(params['limit'] ?? ''), 50);
    expect(
      params.keys.toSet(),
      {'q', 'context', 'unit_id', 'page', 'limit'},
      reason: 'every parameter must exist on the backend PersonSearchParams',
    );

    expect(page.total, 51);
    expect(page.page, 2);
    expect(page.items.single.person.personId, 42);
    expect(page.items.single.unitLabels, ['A Blok D:12']);
    expect(page.items.single.allowed, isTrue);
  });

  test('search omits empty text and optional scope', () async {
    Uri? sent;
    ApiClient.transport = MockClient((request) async {
      sent = request.url;
      return http.Response(
        jsonEncode({'items': [], 'total': 0, 'page': 1, 'page_size': 50}),
        200,
        headers: {'content-type': 'application/json'},
      );
    });

    final page = await const PersonDirectoryRepository().search(query: '   ');

    expect(sent!.queryParameters.keys.toSet(), {'page', 'limit'});
    expect(page.items, isEmpty);
  });
}
