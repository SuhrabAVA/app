import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';

import 'analytics_record.dart';

/// Провайдер для хранения и обработки записей аналитики.
///
/// Мониторит узел `analytics` в Realtime Database и обеспечивает
/// возможность добавлять новые записи. Записи читаются в реальном времени
/// и отсортированы по временной метке.
class AnalyticsProvider with ChangeNotifier {
  final DatabaseReference _logsRef =
      FirebaseDatabase.instance.ref('analytics');

  final List<AnalyticsRecord> _logs = [];

  AnalyticsProvider() {
    _listenToLogs();
  }

  List<AnalyticsRecord> get logs => List.unmodifiable(_logs);

  void _listenToLogs() {
    _logsRef.onValue.listen((event) {
      final data = event.snapshot.value;
      _logs.clear();
      if (data is Map) {
        data.forEach((key, value) {
          if (value is Map) {
            final map = Map<String, dynamic>.from(value as Map);
            _logs.add(AnalyticsRecord.fromMap(map, key));
          }
        });
      }
      // Сортируем по временной метке (самые новые сверху)
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
  }) async {
    final ref = _logsRef.push();
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    await ref.set({
      'orderId': orderId,
      'stageId': stageId,
      'userId': userId,
      'action': action,
      'timestamp': timestamp,
    });
  }
}