import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Лёгкий сервис аудита: пишет login/logout/важные события в таблицу
/// `public.analytics`. Заменяет старый AnalyticsProvider — нужен, чтобы
/// не ломать существующее логирование при переходе на новый модуль
/// аналитики производства.
class AuditLogService {
  AuditLogService({SupabaseClient? client})
      : _supabase = client ?? Supabase.instance.client;

  final SupabaseClient _supabase;
  bool _disabled = false;

  Future<void> logEvent({
    required String userId,
    required String action,
    String orderId = '',
    String stageId = '',
    String category = '',
    String details = '',
  }) async {
    if (_disabled) return;
    try {
      await _supabase.from('analytics').insert({
        'orderId': orderId,
        'stageId': stageId,
        'userId': userId,
        'action': action,
        'category': category,
        'details': details,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      });
    } on PostgrestException catch (e) {
      if (e.code == 'PGRST205') {
        _disabled = true;
        debugPrint('Audit log disabled: table public.analytics is missing');
      } else {
        debugPrint('Audit log error: ${e.message}');
      }
    } catch (e) {
      debugPrint('Audit log error: $e');
    }
  }
}
