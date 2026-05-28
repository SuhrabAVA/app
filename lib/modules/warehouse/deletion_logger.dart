import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../utils/auth_helper.dart';

class DeletionLogger {
  static final SupabaseClient _client = Supabase.instance.client;

  static Future<void> log({
    required String entityType,
    required String entityId,
    required Map<String, dynamic> payload,
    String? reason,
    Map<String, dynamic>? extra,
  }) async {
    final data = <String, dynamic>{
      'id': const Uuid().v4(),
      'entity_type': entityType,
      'entity_id': entityId,
      'payload': payload,
      'deleted_by': (AuthHelper.currentUserName ?? '').trim(),
      'deleted_at': DateTime.now().toUtc().toIso8601String(),
      if (reason != null && reason.trim().isNotEmpty) 'reason': reason.trim(),
      if (extra != null && extra.isNotEmpty) 'extra': extra,
    };
    try {
      await _client.from('warehouse_deleted_records').insert(data);
    } catch (e, st) {
      debugPrint('⚠️ failed to log deletion for $entityType/$entityId: $e');
      debugPrintStack(stackTrace: st);
    }
  }
}
