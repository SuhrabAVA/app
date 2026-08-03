import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/analytics_permission_service.dart';

/// Фиксированные ставки за смену по статусам сотрудников
/// (employee_status_pay_rates), версионируется по месяцу — по образцу
/// WorkplaceCoefficientRepository.
class EmployeeStatusPayRateRepository {
  EmployeeStatusPayRateRepository({SupabaseClient? client})
      : _client = client ?? Supabase.instance.client;

  final SupabaseClient _client;

  /// Загружает ставки по всем статусам. Возвращает map:
  /// statusId -> fixed_day_pay (для выбранного месяца). Если ставки нет в
  /// выбранном месяце — берётся последняя предыдущая по effective_month.
  Future<Map<String, double>> loadEffective(DateTime month) async {
    final firstDay = DateTime(month.year, month.month, 1);
    final isoFirst = _isoDate(firstDay);

    final List<dynamic> rows = await _client
        .from('employee_status_pay_rates')
        .select('status_id, fixed_day_pay, effective_month')
        .lte('effective_month', isoFirst)
        .order('effective_month', ascending: false);

    final result = <String, double>{};
    for (final row in rows) {
      if (row is! Map) continue;
      final statusId = (row['status_id'] ?? '').toString();
      if (statusId.isEmpty) continue;
      if (result.containsKey(statusId)) continue;
      final raw = row['fixed_day_pay'];
      final value = raw is num ? raw.toDouble() : double.tryParse('$raw') ?? 0;
      result[statusId] = value;
    }
    return result;
  }

  Future<void> upsert({
    required AnalyticsPermissionService? permission,
    required String statusId,
    required double fixedDayPay,
    required DateTime month,
    String? updatedBy,
  }) async {
    if (permission?.canEdit != true) {
      throw StateError('У вас нет прав на изменение финансовых данных.');
    }
    final iso = _isoDate(DateTime(month.year, month.month, 1));
    await _client.from('employee_status_pay_rates').upsert(
      {
        'status_id': statusId,
        'fixed_day_pay': fixedDayPay,
        'effective_month': iso,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
        if (updatedBy != null) 'updated_by': updatedBy,
      },
      onConflict: 'status_id,effective_month',
    );
  }

  static String _isoDate(DateTime dt) {
    final y = dt.year.toString().padLeft(4, '0');
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }
}
