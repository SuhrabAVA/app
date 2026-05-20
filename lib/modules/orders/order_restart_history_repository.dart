
import 'package:postgrest/postgrest.dart';

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

  DateTime? get timelineAt => completedAt ?? archivedAt ?? updatedAt;

  DateTime? get finishedAt => timelineAt;

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

  static final RegExp _uuidPattern = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
  );

  @override
  Future<OrderRestartHistoryEntry?> loadOrderById(String orderId) async {
    final id = orderId.trim();
    if (id.isEmpty || !_uuidPattern.hasMatch(id)) return null;

    Future<Map<String, dynamic>?> runSelect(String columns) {
      return _client.from('orders').select(columns).eq('id', id).maybeSingle();
    }

    Map<String, dynamic>? row;
    try {
      row = await runSelect(
          'id,restarted_from_order_id,completed_at,archived_at,updated_at');
    } on PostgrestException catch (_) {
      row = await runSelect('id,restarted_from_order_id,updated_at');
    }



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
    if (!_uuidPattern.hasMatch(id)) return const [];

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
