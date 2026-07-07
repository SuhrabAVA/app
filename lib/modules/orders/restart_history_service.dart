import 'package:flutter/foundation.dart';

import 'order_restart_history_repository.dart';

class RestartHistoryService {
  RestartHistoryService(this._repository);

  final OrderRestartHistoryRepository _repository;

  Future<List<OrderRestartHistoryEntry>> loadRestartHistoryChain(
    String orderId, {
    int limit = 200,
    bool preferRpc = false,
  }) async {
    final id = orderId.trim();
    if (id.isEmpty || limit <= 0) return const [];

    if (preferRpc) {
      try {
        final history =
            await _repository.loadRestartHistoryChainViaRpc(id, limit: limit);
        if (history.isNotEmpty) {
          final ancestors = history.where((entry) => entry.id != id).toList();
          ancestors.sort(_sortByFinishTimeFromOldToNew);
          return ancestors;
        }
      } catch (error, stackTrace) {
        debugPrint(
          'RestartHistoryService RPC fallback: $error\n$stackTrace',
        );
      }
    }

    final visited = <String>{id};
    final chain = <OrderRestartHistoryEntry>[];
    var currentId = id;

    while (chain.length < limit) {
      final current = await _repository.loadOrderById(currentId);
      if (current == null) {
        break;
      }

      final parentId = current.restartedFromOrderId?.trim();
      if (parentId == null || parentId.isEmpty) {
        break;
      }

      if (!visited.add(parentId)) {
        break;
      }

      final parent = await _repository.loadOrderById(parentId);
      if (parent == null) {
        break;
      }

      chain.add(parent);
      currentId = parent.id;
    }

    chain.sort(_sortByFinishTimeFromOldToNew);
    return chain;
  }

  /// Полная цепочка поколений заказа (оригинал и все возобновления),
  /// отсортированная от оригинала к последнему возобновлению.
  /// Запрошенный заказ помечается флагом [OrderGenerationEntry.isCurrent].
  /// Пустой список — если заказ не найден; один элемент — если у заказа
  /// нет ни предков, ни потомков (переключатель в UI не показывается).
  Future<List<OrderGenerationEntry>> loadGenerationChain(
    String orderId,
  ) async {
    final id = orderId.trim();
    if (id.isEmpty) return const [];

    List<OrderGenerationEntry> entries;
    try {
      entries = await _repository.loadGenerationChain(id);
    } catch (error, stackTrace) {
      debugPrint('RestartHistoryService generation chain: $error\n$stackTrace');
      return const [];
    }

    // Дедупликация по id (на случай пересечения условий выборки).
    final seen = <String>{};
    final unique = <OrderGenerationEntry>[
      for (final entry in entries)
        if (seen.add(entry.id)) entry,
    ];

    unique.sort((a, b) {
      final byGeneration = a.generation.compareTo(b.generation);
      if (byGeneration != 0) return byGeneration;
      final aTs = a.createdAt;
      final bTs = b.createdAt;
      if (aTs != null && bTs != null) {
        final byCreated = aTs.compareTo(bTs);
        if (byCreated != 0) return byCreated;
      } else if (aTs != null || bTs != null) {
        return aTs == null ? -1 : 1;
      }
      return a.id.compareTo(b.id);
    });

    return [
      for (final entry in unique) entry.copyWith(isCurrent: entry.id == id),
    ];
  }

  static int _sortByFinishTimeFromOldToNew(
    OrderRestartHistoryEntry a,
    OrderRestartHistoryEntry b,
  ) {
    final aTs = a.finishedAt;
    final bTs = b.finishedAt;

    if (aTs == null && bTs == null) return a.id.compareTo(b.id);
    if (aTs == null) return -1;
    if (bTs == null) return 1;

    final byTime = aTs.compareTo(bTs);
    if (byTime != 0) return byTime;
    return a.id.compareTo(b.id);
  }
}
