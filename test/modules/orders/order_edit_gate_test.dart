import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sheet_clone/modules/orders/order_edit_gate.dart';
import 'package:sheet_clone/modules/orders/order_edit_lease.dart';
import 'package:sheet_clone/modules/orders/order_model.dart';
import 'package:sheet_clone/modules/orders/product_model.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

OrderModel _order(String id, String customer) => OrderModel(
      id: id,
      manager: 'Менеджер',
      customer: customer,
      orderDate: DateTime(2026, 9, 16),
      dueDate: DateTime(2026, 9, 20),
      product: ProductModel(
        id: 'product-1',
        type: 'Пакет',
        quantity: 100,
        width: 10,
        height: 20,
        depth: 0,
      ),
      status: 'newOrder',
    );

void main() {
  late SupabaseClient client;
  late Map<String, dynamic> acquisition;
  late bool functionsMissing;
  late String storedCustomer;

  setUp(() {
    acquisition = {'acquired': true};
    functionsMissing = false;
    storedCustomer = 'Свежий заказчик';
    OrderEditLockSupport.installed = true;
    client = SupabaseClient(
      'https://example.supabase.co',
      'test-key',
      httpClient: MockClient((request) async {
        const jsonHeaders = {'content-type': 'application/json'};
        if (request.url.path.endsWith('/rpc/acquire_order_edit')) {
          if (functionsMissing) {
            return http.Response(
                jsonEncode({
                  'code': 'PGRST202',
                  'message':
                      'Could not find the function public.acquire_order_edit',
                }),
                404,
                request: request,
                headers: jsonHeaders);
          }
          return http.Response(jsonEncode(acquisition), 200,
              request: request, headers: jsonHeaders);
        }
        if (request.url.path.endsWith('/rest/v1/orders')) {
          return http.Response(
              jsonEncode(_order('order-1', storedCustomer).toMap()), 200,
              request: request, headers: jsonHeaders);
        }
        return http.Response('null', 200,
            request: request, headers: jsonHeaders);
      }),
    );
  });

  tearDown(() async {
    await client.dispose();
    OrderEditLockSupport.installed = true;
  });

  Future<void> pump(WidgetTester tester) => tester.pumpWidget(MaterialApp(
        home: OrderEditGate(
          orderId: 'order-1',
          client: client,
          initialOrder: _order('order-1', 'Старый снимок'),
          builder: (fresh, lease) =>
              Scaffold(body: Text('форма: ${fresh.customer}')),
          fallbackBuilder: (stale) =>
              Scaffold(body: Text('форма: ${stale.customer}')),
        ),
      ));

  testWidgets('acquired editor gets the freshly reloaded order', (tester) async {
    await pump(tester);
    await tester.pumpAndSettle();
    expect(find.text('форма: Свежий заказчик'), findsOneWidget);
  });

  testWidgets('busy order keeps the form closed and names the editor',
      (tester) async {
    acquisition = {'acquired': false, 'editor_name': 'Анна'};
    await pump(tester);
    await tester.pumpAndSettle();
    expect(find.textContaining('Анна'), findsOneWidget);
    expect(find.textContaining('форма:'), findsNothing);
  });

  testWidgets('without the migration the form opens and stays usable '
      'after the warning is dismissed', (tester) async {
    functionsMissing = true;
    await pump(tester);
    await tester.pumpAndSettle();
    expect(find.textContaining('Блокировка редактирования ещё не установлена'),
        findsOneWidget);
    expect(find.text('форма: Свежий заказчик'), findsOneWidget);

    await tester.tap(find.text('Скрыть'));
    await tester.pumpAndSettle();
    // Скрытое предупреждение не должно запирать форму пустым экраном.
    expect(find.text('форма: Свежий заказчик'), findsOneWidget);
    expect(find.text('Закрыть редактор'), findsNothing);
    expect(find.byType(AbsorbPointer).evaluate().where((e) {
      final widget = e.widget as AbsorbPointer;
      return widget.absorbing;
    }), isEmpty);
  });
}
