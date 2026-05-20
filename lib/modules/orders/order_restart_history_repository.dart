import 'package:supabase_flutter/supabase_flutter.dart';
import '../tasks/task_model.dart';

class RestartHistoryOrder {
  const RestartHistoryOrder({
    required this.orderId,
    required this.orderName,
    required this.completedAt,
    required this.restartGeneration,
    required this.restartedFromOrderId,
  });

  final String orderId;
  final String orderName;
  final DateTime? completedAt;
  final int restartGeneration;
  final String? restartedFromOrderId;
}

class OrderRestartHistoryRepository {
  OrderRestartHistoryRepository({SupabaseClient? supabase})
      : _supabase = supabase ?? Supabase.instance.client;

  final SupabaseClient _supabase;

  Future<List<RestartHistoryOrder>> loadRestartHistoryChain(String orderId) async {
    final rows = await _supabase.rpc('get_order_restart_history', params: {
      'p_order_id': orderId,
      'p_limit': 200,
    });
    if (rows is! List) return const [];
    return rows.whereType<Map>().map((raw) {
      final row = Map<String, dynamic>.from(raw);
      final completedAtRaw = row['completed_at']?.toString();
      return RestartHistoryOrder(
        orderId: (row['order_id'] ?? '').toString(),
        orderName: (row['order_name'] ?? '').toString(),
        completedAt: completedAtRaw == null || completedAtRaw.isEmpty
            ? null
            : DateTime.tryParse(completedAtRaw),
        restartGeneration: (row['restart_generation'] as num?)?.toInt() ?? 0,
        restartedFromOrderId: row['restarted_from_order_id']?.toString(),
      );
    }).where((e) => e.orderId.isNotEmpty).toList(growable: false);
  }

  Future<List<TaskComment>> loadCommentsForHistoryOrder({
    required String orderId,
    required Set<String> stageIds,
  }) async {
    final query = _supabase.from('tasks').select('comments').eq('order_id', orderId);
    final rows = stageIds.isEmpty ? await query : await query.inFilter('stage_id', stageIds.toList());
    if (rows is! List) return const [];
    final comments = <TaskComment>[];
    for (final rowRaw in rows.whereType<Map>()) {
      final row = Map<String, dynamic>.from(rowRaw);
      final dynamic rawComments = row['comments'];
      Iterable<Map<String, dynamic>> maps = const [];
      if (rawComments is List) {
        maps = rawComments.whereType<Map>().map((e) => Map<String, dynamic>.from(e));
      } else if (rawComments is Map) {
        maps = rawComments.values.whereType<Map>().map((e) => Map<String, dynamic>.from(e));
      }
      for (final map in maps) {
        comments.add(TaskComment.fromMap(map, (map['id'] ?? '').toString()));
      }
    }
    comments.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return comments;
  }
}
