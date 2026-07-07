
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

/// Одно поколение в цепочке возобновлений заказа.
class OrderGenerationEntry {
  final String id;
  final String? restartedFromOrderId;
  final int generation;
  final DateTime? createdAt;
  final DateTime? orderDate;
  final DateTime? completedAt;
  final DateTime? updatedAt;
  final String? status;
  final bool isCurrent;

  const OrderGenerationEntry({
    required this.id,
    required this.generation,
    this.restartedFromOrderId,
    this.createdAt,
    this.orderDate,
    this.completedAt,
    this.updatedAt,
    this.status,
    this.isCurrent = false,
  });

  /// Дата создания поколения для подписи кнопки-переключателя.
  DateTime? get displayDate => orderDate ?? createdAt;

  OrderGenerationEntry copyWith({bool? isCurrent}) => OrderGenerationEntry(
        id: id,
        generation: generation,
        restartedFromOrderId: restartedFromOrderId,
        createdAt: createdAt,
        orderDate: orderDate,
        completedAt: completedAt,
        updatedAt: updatedAt,
        status: status,
        isCurrent: isCurrent ?? this.isCurrent,
      );

  factory OrderGenerationEntry.fromMap(Map<String, dynamic> row) {
    DateTime? parseTs(dynamic v) {
      if (v == null) return null;
      return DateTime.tryParse(v.toString())?.toUtc();
    }

    final id = (row['id'] ?? '').toString().trim();
    if (id.isEmpty) {
      throw const FormatException('Order generation row has empty id');
    }

    final genRaw = row['restart_generation'];
    final generation =
        genRaw is num ? genRaw.toInt() : int.tryParse('$genRaw') ?? 0;

    return OrderGenerationEntry(
      id: id,
      generation: generation,
      restartedFromOrderId: (row['restarted_from_order_id'] as String?)?.trim(),
      createdAt: parseTs(row['created_at']),
      orderDate: parseTs(row['order_date']),
      completedAt: parseTs(row['completed_at']),
      updatedAt: parseTs(row['updated_at']),
      status: (row['status'] as String?)?.trim(),
    );
  }
}

abstract class OrderRestartHistoryRepository {
  Future<OrderRestartHistoryEntry?> loadOrderById(String orderId);

  Future<List<OrderRestartHistoryEntry>> loadRestartHistoryChainViaRpc(
    String orderId, {
    int limit = 200,
  });

  /// Полная цепочка поколений (оригинал и все возобновления) для заказа.
  Future<List<OrderGenerationEntry>> loadGenerationChain(String orderId);
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

  @override
  Future<List<OrderGenerationEntry>> loadGenerationChain(
      String orderId) async {
    final id = orderId.trim();
    if (id.isEmpty || !_uuidPattern.hasMatch(id)) return const [];

    try {
      final rows = await _client.rpc(
        'get_order_generation_chain',
        params: {'p_order_id': id},
      ) as List<dynamic>;
      return rows
          .map((row) => OrderGenerationEntry.fromMap(
              Map<String, dynamic>.from(row as Map)))
          .toList(growable: false);
    } on PostgrestException {
      // RPC может отсутствовать в старых окружениях — собираем цепочку
      // напрямую по restart_root_order_id (двумя запросами).
      return _loadGenerationChainDirect(id);
    }
  }

  Future<List<OrderGenerationEntry>> _loadGenerationChainDirect(
      String orderId) async {
    final row = await _client
        .from('orders')
        .select('id,restart_root_order_id')
        .eq('id', orderId)
        .maybeSingle();
    if (row == null) return const [];

    final rootRaw = (row['restart_root_order_id'] as String?)?.trim();
    final rootId = (rootRaw == null || rootRaw.isEmpty) ? orderId : rootRaw;

    Future<List<dynamic>> runSelect(String columns) {
      return _client
          .from('orders')
          .select(columns)
          .or('id.eq.$rootId,restart_root_order_id.eq.$rootId')
          .order('restart_generation', ascending: true)
          .order('created_at', ascending: true);
    }

    List<dynamic> rows;
    try {
      rows = await runSelect(
          'id,restarted_from_order_id,restart_root_order_id,'
          'restart_generation,created_at,order_date,completed_at,'
          'updated_at,status');
    } on PostgrestException catch (_) {
      rows = await runSelect(
          'id,restarted_from_order_id,restart_root_order_id,'
          'restart_generation,created_at,updated_at');
    }

    return rows
        .map((r) =>
            OrderGenerationEntry.fromMap(Map<String, dynamic>.from(r as Map)))
        .toList(growable: false);
  }
}