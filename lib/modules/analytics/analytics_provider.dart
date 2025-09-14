import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../services/doc_db.dart';
import 'analytics_record.dart';

/// Провайдер для хранения и обработки записей аналитики.
///
/// Использует универсальную таблицу `documents` с коллекцией `analytics`.
/// Записи читаются в реальном времени и отсортированы по временной метке.
class AnalyticsProvider with ChangeNotifier {
    final SupabaseClient _supabase = Supabase.instance.client;
    final DocDB _docDb = DocDB();

  final List<AnalyticsRecord> _logs = [];

  AnalyticsProvider() {
    _listenToLogs();
  }

  List<AnalyticsRecord> get logs => List.unmodifiable(_logs);

  void _listenToLogs() {
    // Listen to realtime updates from the `analytics` table. In some
    // deployments the table might be missing which would normally throw
    // an unhandled [PostgrestException]. To prevent the application from
    // crashing we handle errors from the stream explicitly.
    try {
      _supabase
          .from('documents')
          .stream(primaryKey: ['id'])
          .eq('collection', 'analytics')
          .listen(
        (rows) {
          _logs
            ..clear()
            ..addAll(rows.map((row) {
              final data =
                  Map<String, dynamic>.from((row['data'] ?? {}) as Map);
              final id = row['id'].toString();
              return AnalyticsRecord.fromMap(data, id);
            }));
          _logs.sort((a, b) => b.timestamp.compareTo(a.timestamp));
          notifyListeners();
        },
        onError: (error, stackTrace) {
          // Log the error but keep the app running. If the table is missing
          // we simply skip analytics collection.
          debugPrint('Analytics stream error: $error');
        },
      );
    } on PostgrestException catch (e) {
      // The initial call to `stream` itself can throw synchronously if the
      // table does not exist in the schema cache. We catch it here so that the
      // exception does not bubble up to the framework.
      debugPrint('Failed to subscribe to analytics: ${e.message}');
    }
  }

  /// Добавляет новую запись в базу. Возвращает Future для ожидания
  /// завершения операции записи.
  Future<void> logEvent({
    required String orderId,
    required String stageId,
    required String userId,
    required String action,
    String category = '',
    String details = '',
  }) async {
    
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    try {
      await _docDb.insert('analytics', {
        'orderId': orderId,
        'stageId': stageId,
        'userId': userId,
        'action': action,
        'category': category,
        'details': details,
        'timestamp': timestamp,
      });
    } on PostgrestException catch (e) {
      // If the table is missing or insertion fails for any reason we simply
      // log the issue and move on.
      debugPrint('Failed to log analytics event: ${e.message}');
    }
  }
}