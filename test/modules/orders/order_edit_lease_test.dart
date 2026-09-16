import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sheet_clone/modules/orders/order_edit_lease.dart';
import 'package:sheet_clone/services/order_edit_http_client.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  late SupabaseClient client;
  late Map<String, dynamic> acquisition;
  late bool renewOk;
  late bool networkError;
  late bool functionsMissing;
  late List<String> calls;

  setUp(() {
    acquisition = {'acquired': true};
    renewOk = true;
    networkError = false;
    functionsMissing = false;
    OrderEditLockSupport.installed = true;
    calls = [];
    client = SupabaseClient(
      'https://example.supabase.co',
      'test-key',
      httpClient: MockClient((request) async {
        final name = request.url.path.split('/').last;
        calls.add(name);
        if (functionsMissing) {
          return http.Response(
              jsonEncode({
                'code': 'PGRST202',
                'message': 'Could not find the function public.$name',
              }),
              404,
              request: request,
              headers: {'content-type': 'application/json'});
        }
        if (name == 'renew_order_edit' && networkError) {
          return http.Response('{"message":"offline"}', 503, request: request);
        }
        return http.Response(
            jsonEncode(switch (name) {
              'acquire_order_edit' => acquisition,
              'renew_order_edit' => renewOk,
              _ => null,
            }),
            200,
            request: request,
            headers: {'content-type': 'application/json'});
      }),
    );
  });

  tearDown(() async {
    await client.dispose();
    OrderEditTokens.active.clear();
    OrderEditLockSupport.installed = true;
  });

  test('busy editor cannot write or release the other editor lease', () async {
    acquisition = {'acquired': false, 'editor_name': 'Анна'};
    final lease = OrderEditLease('order-1', client: client);
    expect(await lease.acquire(), OrderEditLeaseStatus.busy);
    expect(lease.message, contains('Анна'));
    expect(OrderEditTokens.active, isEmpty);
    lease.dispose();
    expect(calls, ['acquire_order_edit']);
  });

  test('missing server functions degrade to compatibility instead of failing',
      () async {
    functionsMissing = true;
    final lease = OrderEditLease('order-1', client: client);
    expect(await lease.acquire(), OrderEditLeaseStatus.unavailable);
    expect(lease.unavailable, isTrue);
    expect(OrderEditLockSupport.installed, isFalse);
    expect(OrderEditTokens.active, isEmpty);
    // Сохранение не запрещается: блокировки нет ни у кого.
    expect(await lease.renew(), isTrue);
    await lease.ensureOwned();
    // Второй редактор больше не ходит за несуществующей функцией.
    final second = OrderEditLease('order-2', client: client);
    expect(await second.acquire(), OrderEditLeaseStatus.unavailable);
    expect(calls, ['acquire_order_edit']);
    lease.dispose();
    second.dispose();
  });

  test('acquire registers a unique capability and close releases it', () async {
    final lease = OrderEditLease('order-1', client: client);
    expect(await lease.acquire(), OrderEditLeaseStatus.acquired);
    expect(OrderEditTokens.active['order-1'], lease.token);
    await lease.ensureOwned();
    lease.dispose();
    await Future<void>.delayed(Duration.zero);
    expect(calls, contains('release_order_edit'));
    expect(OrderEditTokens.active, isEmpty);
  });

  test('failed heartbeat blocks editing; transient connection can recover',
      () async {
    final lease = OrderEditLease('order-1', client: client);
    await lease.acquire();
    networkError = true;
    expect(await lease.renew(), isFalse);
    expect(lease.ready, isFalse);
    networkError = false;
    expect(await lease.renew(), isTrue);
    lease.dispose();
    await Future<void>.delayed(Duration.zero);
  });

  test('expired editor cannot reacquire silently and overwrite a newer order',
      () async {
    final lease = OrderEditLease('order-1', client: client);
    await lease.acquire();
    renewOk = false;
    expect(await lease.renew(), isFalse);
    renewOk = true;
    await expectLater(lease.ensureOwned(), throwsStateError);
    expect(calls.where((c) => c == 'acquire_order_edit'), hasLength(1));
    // Keep sending the expired token so a pending write cannot look unlocked.
    expect(OrderEditTokens.active['order-1'], lease.token);
    lease.dispose();
    await Future<void>.delayed(Duration.zero);
  });

  test('capabilities are only sent to this Supabase REST endpoint', () async {
    final seen = <http.Request>[];
    final transport = OrderEditHttpClient(
        Uri.parse('https://example.supabase.co'), inner: MockClient((r) async {
      seen.add(r);
      return http.Response('{}', 200);
    }));
    OrderEditTokens.active['order-1'] = 'secret-token';
    await transport
        .get(Uri.parse('https://example.supabase.co/rest/v1/orders'));
    await transport
        .get(Uri.parse('https://example.supabase.co/storage/v1/file'));
    await transport.get(Uri.parse('https://another.example/rest/v1/orders'));
    expect(jsonDecode(seen[0].headers['x-order-edit-tokens']!),
        {'order-1': 'secret-token'});
    expect(seen[1].headers.containsKey('x-order-edit-tokens'), isFalse);
    expect(seen[2].headers.containsKey('x-order-edit-tokens'), isFalse);
    transport.close();
  });
}
