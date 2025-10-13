import 'package:supabase_flutter/supabase_flutter.dart';

import '../../utils/auth_helper.dart';

/// Repository that stores and retrieves deleted warehouse records.
class DeletedRecordsRepository {
  static final SupabaseClient _sb = Supabase.instance.client;

  /// Archives a record into the `warehouse_deleted_records` table.
  ///
  /// [entityType] is a stable key like `tmc_paper` or `category_item`.
  /// [payload] keeps the original row so it can be displayed later.
  static Future<void> archive({
    required String entityType,
    Map<String, dynamic>? payload,
    String? entityId,
    String? reason,
  }) async {
    try {
      final data = <String, dynamic>{
        'entity_type': entityType,
        if (entityId != null) 'entity_id': entityId,
        if (payload != null) 'payload': payload,
        if (reason != null && reason.trim().isNotEmpty) 'reason': reason.trim(),
        if ((AuthHelper.currentUserName ?? '').isNotEmpty)
          'deleted_by': AuthHelper.currentUserName,
      };
      await _sb.from('warehouse_deleted_records').insert(data);
    } catch (_) {
      // Archiving should not break the main flow.
    }
  }

  /// Loads deleted records for particular [entityType].
  static Future<List<Map<String, dynamic>>> fetch(String entityType) async {
    try {
      final res = await _sb
          .from('warehouse_deleted_records')
          .select()
          .eq('entity_type', entityType)
          .order('deleted_at', ascending: false);
      final list = (res as List?) ?? const [];
      return list
          .whereType<Map<String, dynamic>>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    } catch (_) {
      return const [];
    }
  }
}
