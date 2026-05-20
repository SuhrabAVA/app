import 'package:supabase_flutter/supabase_flutter.dart';

class OrderRestartHistoryEntry {
  final String id;
  final String? restartedFromOrderId;
  final DateTime? completedAt;
  final DateTime? archivedAt;
  final DateTime? updatedAt;

  const OrderRestartHistoryEntry({
    required this.id,
    required this.restartedFromOrderId,
    this.completedAt,
    this.archivedAt,
    this.updatedAt,
  });

  DateTime? get finishedAt => completedAt ?? archivedAt ?? updatedAt;

  factory OrderRestartHistoryEntry.fromMap(Map<String, dynamic> row) {
    DateTime? parseTs(dynamic v) {
      if (v == null) return null;
      return DateTime.tryParse(v.toString())?.toUtc();
    }

    final id = (row['id'] ?? '').toString().trim();
    if (id.isEmpty) {
      throw const FormatException('Order restart history row has empty id');
    }

    return OrderRestartHistoryEntry(
      id: id,
      restartedFromOrderId: (row['restarted_from_order_id'] as String?)?.trim(),
      completedAt: parseTs(row['completed_at']),
      archivedAt: parseTs(row['archived_at']),
      updatedAt: parseTs(row['updated_at']),
    );
  }
}

abstract class OrderRestartHistoryRepository {
  Future<OrderRestartHistoryEntry?> loadOrderById(String orderId);

  Future<List<OrderRestartHistoryEntry>> loadRestartHistoryChainViaRpc(
    String orderId, {
    int limit = 200,
  });
}

class SupabaseOrderRestartHistoryRepository
    implements OrderRestartHistoryRepository {
  SupabaseOrderRestartHistoryRepository({SupabaseClient? client})
      : _client = client ?? Supabase.instance.client;

  final SupabaseClient _client;

  @override
  Future<OrderRestartHistoryEntry?> loadOrderById(String orderId) async {
    final id = orderId.trim();
    if (id.isEmpty) return null;

    final row = await _client
        .from('orders')
        .select('id,restarted_from_order_id,completed_at,archived_at,updated_at')
        .eq('id', id)
        .maybeSingle();

    if (row == null) return null;
    return OrderRestartHistoryEntry.fromMap(row);
  }

  @override
  Future<List<OrderRestartHistoryEntry>> loadRestartHistoryChainViaRpc(
    String orderId, {
    int limit = 200,
  }) async {
    final id = orderId.trim();
    if (id.isEmpty || limit <= 0) return const [];

    final rows = await _client.rpc(
      'get_order_restart_history',
      params: {'p_order_id': id, 'p_limit': limit},
    ) as List<dynamic>;

    return rows
        .map((row) => OrderRestartHistoryEntry.fromMap(
            Map<String, dynamic>.from(row as Map)))
        .toList(growable: false);
  }
}
