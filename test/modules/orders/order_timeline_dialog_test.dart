import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:sheet_clone/modules/orders/order_model.dart';
import 'package:sheet_clone/modules/orders/order_restart_history_repository.dart';
import 'package:sheet_clone/modules/orders/order_timeline_dialog.dart';
import 'package:sheet_clone/modules/orders/product_model.dart';
import 'package:sheet_clone/modules/orders/restart_history_service.dart';
import 'package:sheet_clone/modules/personnel/personnel_provider.dart';
import 'package:sheet_clone/services/personnel_db.dart';

class _FakePersonnelDB implements PersonnelDB {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeHistoryRepository implements OrderRestartHistoryRepository {
  _FakeHistoryRepository(this.chain);

  final List<OrderGenerationEntry> chain;

  @override
  Future<OrderRestartHistoryEntry?> loadOrderById(String orderId) async => null;

  @override
  Future<List<OrderRestartHistoryEntry>> loadRestartHistoryChainViaRpc(
    String orderId, {
    int limit = 200,
  }) async =>
      const [];

  @override
  Future<List<OrderGenerationEntry>> loadGenerationChain(
          String orderId) async =>
      chain;
}

OrderModel _order(String id) => OrderModel(
      id: id,
      manager: 'm',
      customer: 'c',
      orderDate: DateTime(2026, 6, 1),
      dueDate: DateTime(2026, 7, 1),
      product: ProductModel(
        id: 'p1',
        type: 'Коробка',
        quantity: 1,
        width: 1,
        height: 1,
        depth: 1,
      ),
    );

Map<String, dynamic> _event(String text) => <String, dynamic>{
      'source': 'order_event',
      'timestamp': null,
      'event_type': 'note',
      'description': text,
    };

Widget _host(Widget dialog) => ChangeNotifierProvider<PersonnelProvider>(
      create: (_) => PersonnelProvider(db: _FakePersonnelDB(), bootstrap: false),
      child: MaterialApp(home: Scaffold(body: dialog)),
    );

void main() {
  testWidgets('заказ без возобновлений — переключателя нет', (tester) async {
    final service = RestartHistoryService(_FakeHistoryRepository([
      const OrderGenerationEntry(id: 'solo', generation: 0, isCurrent: true),
    ]));
    await tester.pumpWidget(_host(OrderTimelineDialog(
      order: _order('solo'),
      events: [_event('Единственная жизнь')],
      loadEvents: (_) async => const [],
      historyService: service,
    )));
    await tester.pumpAndSettle();

    expect(find.byType(ChoiceChip), findsNothing);
    expect(find.text('Единственная жизнь'), findsOneWidget);
  });

  testWidgets(
      '3 возобновления — 4 вкладки; у каждого поколения свой список, лениво',
      (tester) async {
    final chain = [
      OrderGenerationEntry(
          id: 'gen0', generation: 0, orderDate: DateTime(2026, 3, 12)),
      OrderGenerationEntry(
          id: 'gen1', generation: 1, orderDate: DateTime(2026, 4, 15)),
      OrderGenerationEntry(
          id: 'gen2', generation: 2, orderDate: DateTime(2026, 5, 20)),
      const OrderGenerationEntry(id: 'cur', generation: 3, isCurrent: true),
    ];
    final loadCalls = <String>[];
    Future<List<Map<String, dynamic>>> loadEvents(String orderId) async {
      loadCalls.add(orderId);
      return [_event('История $orderId')];
    }

    await tester.pumpWidget(_host(OrderTimelineDialog(
      order: _order('cur'),
      events: [_event('История текущего')],
      loadEvents: loadEvents,
      historyService: RestartHistoryService(_FakeHistoryRepository(chain)),
    )));
    await tester.pumpAndSettle();

    // 4 вкладки: текущий + 3 предыдущих поколения с датами создания.
    expect(find.byType(ChoiceChip), findsNWidgets(4));
    expect(find.text('Этот заказ'), findsOneWidget);
    expect(find.text('12.03.2026'), findsOneWidget);
    expect(find.text('15.04.2026'), findsOneWidget);
    expect(find.text('20.05.2026'), findsOneWidget);
    // Текущее поколение показано из переданных events, без loadEvents.
    expect(find.text('История текущего'), findsOneWidget);
    expect(loadCalls, isEmpty);

    // Открываем оригинал: только его список, ничего не слито.
    await tester.tap(find.text('12.03.2026'));
    await tester.pumpAndSettle();
    expect(find.text('История gen0'), findsOneWidget);
    expect(find.text('История текущего'), findsNothing);
    expect(find.text('История gen1'), findsNothing);
    expect(loadCalls, ['gen0']);

    // Среднее поколение.
    await tester.tap(find.text('15.04.2026'));
    await tester.pumpAndSettle();
    expect(find.text('История gen1'), findsOneWidget);
    expect(find.text('История gen0'), findsNothing);
    expect(loadCalls, ['gen0', 'gen1']);

    // Туда-обратно: история берётся из кэша, повторных загрузок нет.
    await tester.tap(find.text('Этот заказ'));
    await tester.pumpAndSettle();
    expect(find.text('История текущего'), findsOneWidget);
    await tester.tap(find.text('12.03.2026'));
    await tester.pumpAndSettle();
    expect(find.text('История gen0'), findsOneWidget);
    expect(loadCalls, ['gen0', 'gen1']);
  });

  testWidgets('у архивного оригинала видны вкладки потомков-возобновлений',
      (tester) async {
    final chain = [
      const OrderGenerationEntry(id: 'root', generation: 0, isCurrent: true),
      OrderGenerationEntry(
          id: 'revival', generation: 1, orderDate: DateTime(2026, 6, 2)),
    ];
    await tester.pumpWidget(_host(OrderTimelineDialog(
      order: _order('root'),
      events: [_event('История оригинала')],
      loadEvents: (id) async => [_event('История $id')],
      historyService: RestartHistoryService(_FakeHistoryRepository(chain)),
    )));
    await tester.pumpAndSettle();

    expect(find.text('Этот заказ'), findsOneWidget);
    expect(find.text('02.06.2026'), findsOneWidget);

    await tester.tap(find.text('02.06.2026'));
    await tester.pumpAndSettle();
    expect(find.text('История revival'), findsOneWidget);
    expect(find.text('История оригинала'), findsNothing);
  });
}
