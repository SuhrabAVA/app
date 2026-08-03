import 'package:supabase_flutter/supabase_flutter.dart';

import 'setup_count.dart';

/// Последняя наладка на рабочем месте (для сравнения размеров в режиме
/// «По размеру»).
class WorkplaceSetupHistoryEntry {
  final String workplaceId;
  final String orderId;
  final SetupDims dims;
  final DateTime createdAt;

  const WorkplaceSetupHistoryEntry({
    required this.workplaceId,
    required this.orderId,
    required this.dims,
    required this.createdAt,
  });
}

/// Журнал завершённых наладок по рабочим местам (workplace_setup_history).
/// Хронология фактического выполнения: «предыдущий заказ» рабочего места —
/// это последняя запись журнала, а не заказ с ближайшей датой создания.
class WorkplaceSetupHistoryRepository {
  WorkplaceSetupHistoryRepository({SupabaseClient? client})
      : _client = client ?? Supabase.instance.client;

  final SupabaseClient _client;

  Future<WorkplaceSetupHistoryEntry?> loadLast(String workplaceId) async {
    final rows = await _client
        .from('workplace_setup_history')
        .select('workplace_id, order_id, width, height, depth, created_at')
        .eq('workplace_id', workplaceId)
        .order('created_at', ascending: false)
        .limit(1);
    if (rows.isEmpty) return null;
    final row = Map<String, dynamic>.from(rows.first);
    return WorkplaceSetupHistoryEntry(
      workplaceId: (row['workplace_id'] ?? '').toString(),
      orderId: (row['order_id'] ?? '').toString(),
      dims: SetupDims(
        width: _num(row['width']),
        height: _num(row['height']),
        depth: _num(row['depth']),
      ),
      createdAt:
          DateTime.tryParse('${row['created_at']}')?.toUtc() ?? DateTime.now().toUtc(),
    );
  }

  Future<void> insert({
    required String workplaceId,
    required String orderId,
    required String taskId,
    required String employeeId,
    required SetupDims dims,
    required double countedQty,
    String? calcMode,
    String? note,
  }) async {
    await _client.from('workplace_setup_history').insert({
      'workplace_id': workplaceId,
      'order_id': orderId.isEmpty ? null : orderId,
      'task_id': taskId.isEmpty ? null : taskId,
      'employee_id': employeeId.isEmpty ? null : employeeId,
      'width': dims.width,
      'height': dims.height,
      'depth': dims.depth,
      'counted_qty': countedQty,
      'calc_mode': calcMode,
      'note': note,
    });
  }

  static double? _num(dynamic v) {
    if (v == null) return null;
    if (v is num) return v.toDouble();
    return double.tryParse('$v'.replaceAll(',', '.'));
  }
}
