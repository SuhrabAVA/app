import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/workplace_coefficient.dart';

class WorkplaceCoefficientRepository {
  WorkplaceCoefficientRepository({SupabaseClient? client})
      : _client = client ?? Supabase.instance.client;

  final SupabaseClient _client;

  /// Загружает коэффициенты по всем рабочим местам.
  /// Возвращает map: workplaceId -> coefficient (для выбранного месяца).
  /// Если коэффициента нет в выбранном месяце — берётся последний
  /// предыдущий по дате effective_month.
  Future<Map<String, double>> loadEffective(DateTime month) async {
    final firstDay = DateTime(month.year, month.month, 1);
    final isoFirst = _isoDate(firstDay);

    final List<dynamic> rows = await _client
        .from('workplace_coefficients')
        .select('workplace_id, coefficient, effective_month')
        .lte('effective_month', isoFirst)
        .order('effective_month', ascending: false);

    final result = <String, double>{};
    for (final row in rows) {
      if (row is! Map) continue;
      final wpId = (row['workplace_id'] ?? '').toString();
      if (wpId.isEmpty) continue;
      if (result.containsKey(wpId)) continue;
      final raw = row['coefficient'];
      final value = raw is num ? raw.toDouble() : double.tryParse('$raw') ?? 0;
      result[wpId] = value;
    }
    return result;
  }

  Future<List<WorkplaceCoefficient>> listForMonth(DateTime month) async {
    final isoFirst = _isoDate(DateTime(month.year, month.month, 1));
    final List<dynamic> rows = await _client
        .from('workplace_coefficients')
        .select('id, workplace_id, coefficient, effective_month')
        .eq('effective_month', isoFirst);
    return rows
        .whereType<Map>()
        .map((m) => WorkplaceCoefficient.fromMap(Map<String, dynamic>.from(m)))
        .toList();
  }

  Future<void> upsert({
    required String workplaceId,
    required double coefficient,
    required DateTime month,
    String? updatedBy,
  }) async {
    final iso = _isoDate(DateTime(month.year, month.month, 1));
    await _client.from('workplace_coefficients').upsert(
      {
        'workplace_id': workplaceId,
        'coefficient': coefficient,
        'effective_month': iso,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
        if (updatedBy != null) 'updated_by': updatedBy,
      },
      onConflict: 'workplace_id,effective_month',
    );
  }

  static String _isoDate(DateTime dt) {
    final y = dt.year.toString().padLeft(4, '0');
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }
}
