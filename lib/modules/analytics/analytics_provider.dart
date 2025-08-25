import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'analytics_record.dart';

/// Провайдер для хранения и обработки записей аналитики.
///
/// Мониторит таблицу `analytics` в Supabase и обеспечивает возможность
/// добавлять новые записи. Записи читаются в реальном времени и
/// отсортированы по временной метке.
class AnalyticsProvider with ChangeNotifier {
    final SupabaseClient _supabase = Supabase.instance.client;

  final List<AnalyticsRecord> _logs = [];

  AnalyticsProvider() {
    _listenToLogs();
  }

  List<AnalyticsRecord> get logs => List.unmodifiable(_logs);

  void _listenToLogs() {
    _supabase.from('analytics').stream(primaryKey: ['id']).listen((rows) {
      _logs
        ..clear()
        ..addAll(rows.map((row) {
          final map = Map<String, dynamic>.from(row as Map);
          return AnalyticsRecord.fromMap(map, map['id'].toString());
        }));
      _logs.sort((a, b) => b.timestamp.compareTo(a.timestamp));
      notifyListeners();
    });
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
    await _supabase.from('analytics').insert({
      'orderId': orderId,
      'stageId': stageId,
      'userId': userId,
      'action': action,
      'category': category,
      'details': details,
      'timestamp': timestamp,
    });
  }
}