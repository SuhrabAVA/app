import 'package:flutter_test/flutter_test.dart';
import 'package:forma_pack_work/modules/orders/order_restart_history_repository.dart';
import 'package:forma_pack_work/modules/orders/restart_history_service.dart';

class _FakeRestartHistoryRepository implements OrderRestartHistoryRepository {
  _FakeRestartHistoryRepository(this._rows, {this.rpcRows = const []});

  final Map<String, OrderRestartHistoryEntry> _rows;
  final List<OrderRestartHistoryEntry> rpcRows;

  @override
  Future<OrderRestartHistoryEntry?> loadOrderById(String orderId) async =>
      _rows[orderId];

  @override
  Future<List<OrderRestartHistoryEntry>> loadRestartHistoryChainViaRpc(
    String orderId, {
    int limit = 200,
  }) async =>
      rpcRows.take(limit).toList(growable: false);
}

OrderRestartHistoryEntry _entry(
  String id, {
  String? parent,
  String? completedAt,
  String? archivedAt,
  String? updatedAt,
}) {
  return OrderRestartHistoryEntry(
    id: id,
    restartedFromOrderId: parent,
    completedAt: completedAt == null ? null : DateTime.parse(completedAt),
    archivedAt: archivedAt == null ? null : DateTime.parse(archivedAt),
    updatedAt: updatedAt == null ? null : DateTime.parse(updatedAt),
  );
}

void main() {
  test('returns ancestors from old to new with completed/archived/updated fallback',
      () async {
    final repo = _FakeRestartHistoryRepository({
      'C': _entry('C', parent: 'B', updatedAt: '2026-01-03T10:00:00Z'),
      'B': _entry('B', parent: 'A', archivedAt: '2026-01-02T10:00:00Z'),
      'A': _entry('A', completedAt: '2026-01-01T10:00:00Z'),
    });

    final service = RestartHistoryService(repo);
    final chain = await service.loadRestartHistoryChain('C');

    expect(chain.map((e) => e.id).toList(), ['A', 'B']);
  });

  test('stops on cycle and respects limit', () async {
    final repo = _FakeRestartHistoryRepository({
      'C': _entry('C', parent: 'B'),
      'B': _entry('B', parent: 'A'),
      'A': _entry('A', parent: 'C'),
    });

    final service = RestartHistoryService(repo);
    final chain = await service.loadRestartHistoryChain('C', limit: 1);

    expect(chain.length, 1);
    expect(chain.first.id, 'B');
  });

  test('degrades gracefully when ancestor is missing', () async {
    final repo = _FakeRestartHistoryRepository({
      'C': _entry('C', parent: 'B'),
    });

    final service = RestartHistoryService(repo);
    final chain = await service.loadRestartHistoryChain('C');

    expect(chain, isEmpty);
  });
}
