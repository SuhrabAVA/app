import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/salary_settings.dart';
import '../services/analytics_permission_service.dart';

class SalarySettingsRepository {
  SalarySettingsRepository({SupabaseClient? client})
      : _client = client ?? Supabase.instance.client;

  final SupabaseClient _client;

  /// Возвращает настройки для месяца. Если для месяца их нет — берёт
  /// последние более ранние.
  Future<SalarySettings> loadEffective(DateTime month) async {
    final firstDay = DateTime(month.year, month.month, 1);
    final iso = _isoDate(firstDay);

    final List<dynamic> rows = await _client
        .from('salary_settings')
        .select('id, effective_month, night_percent, meal_amount, social_default')
        .lte('effective_month', iso)
        .order('effective_month', ascending: false)
        .limit(1);

    if (rows.isEmpty) return SalarySettings.defaults(firstDay);
    final m = rows.first;
    return SalarySettings.fromMap(Map<String, dynamic>.from(m as Map));
  }

  /// Сохраняет настройки для указанного месяца (upsert).
  Future<SalarySettings> save({
    required AnalyticsPermissionService? permission,
    required DateTime month,
    required double nightPercent,
    required double mealAmount,
    required double socialDefault,
    String? updatedBy,
  }) async {
    if (permission?.canEdit != true) {
      throw StateError('У вас нет прав на изменение финансовых данных.');
    }
    final firstDay = DateTime(month.year, month.month, 1);
    final iso = _isoDate(firstDay);
    final result = await _client
        .from('salary_settings')
        .upsert(
          {
            'effective_month': iso,
            'night_percent': nightPercent,
            'meal_amount': mealAmount,
            'social_default': socialDefault,
            'updated_at': DateTime.now().toUtc().toIso8601String(),
            if (updatedBy != null) 'updated_by': updatedBy,
          },
          onConflict: 'effective_month',
        )
        .select()
        .single();
    return SalarySettings.fromMap(Map<String, dynamic>.from(result));
  }

  static String _isoDate(DateTime dt) {
    final y = dt.year.toString().padLeft(4, '0');
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }
}
