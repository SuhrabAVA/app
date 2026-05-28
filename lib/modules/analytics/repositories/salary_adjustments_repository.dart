import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/salary_adjustments.dart';

class SalaryAdjustmentsRepository {
  SalaryAdjustmentsRepository({SupabaseClient? client})
      : _client = client ?? Supabase.instance.client;

  final SupabaseClient _client;

  /// Возвращает корректировки на месяц: employeeId -> SalaryAdjustments.
  Future<Map<String, SalaryAdjustments>> loadForMonth(DateTime month) async {
    final iso = _isoDate(DateTime(month.year, month.month, 1));
    final List<dynamic> rows = await _client
        .from('employee_month_salary_adjustments')
        .select(
            'id, employee_id, month, compensation, social, advance, cashless, discipline, defect')
        .eq('month', iso);

    final result = <String, SalaryAdjustments>{};
    for (final row in rows) {
      if (row is! Map) continue;
      final adj = SalaryAdjustments.fromMap(Map<String, dynamic>.from(row));
      result[adj.employeeId] = adj;
    }
    return result;
  }

  Future<SalaryAdjustments> upsert(SalaryAdjustments adj, {String? updatedBy}) async {
    final iso = _isoDate(DateTime(adj.month.year, adj.month.month, 1));
    final result = await _client
        .from('employee_month_salary_adjustments')
        .upsert({
          'employee_id': adj.employeeId,
          'month': iso,
          'compensation': adj.compensation,
          'social': adj.social,
          'advance': adj.advance,
          'cashless': adj.cashless,
          'discipline': adj.discipline,
          'defect': adj.defect,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
          if (updatedBy != null) 'updated_by': updatedBy,
        }, onConflict: 'employee_id,month')
        .select()
        .single();
    return SalaryAdjustments.fromMap(Map<String, dynamic>.from(result));
  }

  static String _isoDate(DateTime dt) {
    final y = dt.year.toString().padLeft(4, '0');
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }
}
