import 'package:flutter_test/flutter_test.dart';

import 'package:sheet_clone/modules/orders/order_restart_history_repository.dart';
import 'package:sheet_clone/modules/orders/restart_history_service.dart';

class _FakeRepository implements OrderRestartHistoryRepository {
  _FakeRepository({this.chain = const [], this.throwOnChain = false});

  final List<OrderGenerationEntry> chain;
  final bool throwOnChain;

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
      String orderId) async {
    if (throwOnChain) throw Exception('boom');
    return chain;
  }
}

OrderGenerationEntry _entry(
  String id,
  int generation, {
  DateTime? createdAt,
}) =>
    OrderGenerationEntry(id: id, generation: generation, createdAt: createdAt);

void main() {
  group('RestartHistoryService.loadGenerationChain', () {
    test('пустой orderId — пустой список без похода в репозиторий', () async {
      final service = RestartHistoryService(_FakeRepository());
      expect(await service.loadGenerationChain('   '), isEmpty);
    });

    test('ошибка репозитория — пустой список, без исключения', () async {
      final service =
          RestartHistoryService(_FakeRepository(throwOnChain: true));
      expect(await service.loadGenerationChain('order-b'), isEmpty);
    });

    test('сортирует по generation и помечает текущий', () async {
      final service = RestartHistoryService(_FakeRepository(chain: [
        _entry('gen2', 2),
        _entry('gen0', 0),
        _entry('gen1', 1),
      ]));

      final result = await service.loadGenerationChain('gen1');

      expect(result.map((e) => e.id).toList(), ['gen0', 'gen1', 'gen2']);
      expect(result.map((e) => e.isCurrent).toList(), [false, true, false]);
    });

    test('равные generation упорядочиваются по createdAt', () async {
      final service = RestartHistoryService(_FakeRepository(chain: [
        _entry('later', 1, createdAt: DateTime.utc(2026, 3, 12)),
        _entry('earlier', 1, createdAt: DateTime.utc(2026, 1, 5)),
        _entry('root', 0, createdAt: DateTime.utc(2025, 12, 1)),
      ]));

      final result = await service.loadGenerationChain('later');

      expect(result.map((e) => e.id).toList(), ['root', 'earlier', 'later']);
    });

    test('дубли по id схлопываются', () async {
      final service = RestartHistoryService(_FakeRepository(chain: [
        _entry('root', 0),
        _entry('root', 0),
        _entry('child', 1),
      ]));

      final result = await service.loadGenerationChain('child');

      expect(result.map((e) => e.id).toList(), ['root', 'child']);
    });

    test('одно поколение без возобновлений — один элемент, текущий', () async {
      final service = RestartHistoryService(_FakeRepository(chain: [
        _entry('solo', 0),
      ]));

      final result = await service.loadGenerationChain('solo');

      expect(result, hasLength(1));
      expect(result.single.isCurrent, isTrue);
    });
  });

  group('OrderGenerationEntry', () {
    test('fromMap разбирает строку RPC', () {
      final entry = OrderGenerationEntry.fromMap({
        'id': ' abc ',
        'restarted_from_order_id': 'parent',
        'restart_generation': 2,
        'created_at': '2026-03-12T10:00:00+00:00',
        'order_date': '2026-03-11T00:00:00+00:00',
        'completed_at': null,
        'updated_at': '2026-03-13T09:00:00+00:00',
        'status': 'completed',
      });

      expect(entry.id, 'abc');
      expect(entry.generation, 2);
      expect(entry.restartedFromOrderId, 'parent');
      expect(entry.displayDate, DateTime.utc(2026, 3, 11));
      expect(entry.status, 'completed');
      expect(entry.isCurrent, isFalse);
    });

    test('displayDate падает обратно на created_at без order_date', () {
      final entry = OrderGenerationEntry.fromMap({
        'id': 'abc',
        'restart_generation': 0,
        'created_at': '2026-03-12T10:00:00+00:00',
      });

      expect(entry.displayDate, DateTime.utc(2026, 3, 12, 10));
    });
  });
}
