import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/workplace_coefficient.dart';
import '../services/analytics_permission_service.dart';

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

  /// Ставки помощников по рабочим местам: workplaceId -> ₸ за единицу.
  ///
  /// Рабочее место без записи в карту оплачивает помощника по ставке
  /// основного исполнителя (подстановку делает [helperCoefficientOrMain]).
  ///
  /// Колонка добавлена отдельной миграцией; пока она не применена, запрос
  /// падает, и мы возвращаем пустую карту — все получают ставку основного,
  /// как было до появления настройки.
  Future<Map<String, double>> loadEffectiveHelperCoefficients(
      DateTime month) async {
    final isoFirst = _isoDate(DateTime(month.year, month.month, 1));
    try {
      final List<dynamic> rows = await _client
          .from('workplace_coefficients')
          .select('workplace_id, helper_coefficient, effective_month')
          .lte('effective_month', isoFirst)
          .order('effective_month', ascending: false);

      final result = <String, double>{};
      final seen = <String>{};
      for (final row in rows) {
        if (row is! Map) continue;
        final wpId = (row['workplace_id'] ?? '').toString();
        // Более поздний месяц перекрывает ранний — но только записью, которая
        // действительно есть. Пустая ставка в свежем месяце не должна
        // «протаскивать» прошлогоднюю: рабочее место просто получает ставку
        // основного исполнителя.
        if (wpId.isEmpty || seen.contains(wpId)) continue;
        seen.add(wpId);
        final raw = row['helper_coefficient'];
        if (raw == null) continue;
        final value = raw is num ? raw.toDouble() : double.tryParse('$raw');
        if (value == null || !value.isFinite || value < 0) continue;
        result[wpId] = value;
      }
      return result;
    } catch (_) {
      return const <String, double>{};
    }
  }

  Future<List<WorkplaceCoefficient>> listForMonth(DateTime month) async {
    final isoFirst = _isoDate(DateTime(month.year, month.month, 1));
    final List<dynamic> rows = await _client
        .from('workplace_coefficients')
        .select(
            'id, workplace_id, coefficient, helper_coefficient, effective_month')
        .eq('effective_month', isoFirst);
    return rows
        .whereType<Map>()
        .map((m) => WorkplaceCoefficient.fromMap(Map<String, dynamic>.from(m)))
        .toList();
  }

  Future<void> upsert({
    required AnalyticsPermissionService? permission,
    required String workplaceId,
    required double coefficient,
    // Явный флаг «трогать ли колонку»: ставку помощника можно и очистить,
    // вернув оплату по ставке основного, а nullable-семантика «не передали»
    // такой сброс выразить не даёт.
    bool setHelperCoefficient = false,
    double? helperCoefficient,
    required DateTime month,
    String? updatedBy,
  }) async {
    if (permission?.canEdit != true) {
      throw StateError('У вас нет прав на изменение финансовых данных.');
    }
    final iso = _isoDate(DateTime(month.year, month.month, 1));
    await _client.from('workplace_coefficients').upsert(
      {
        'workplace_id': workplaceId,
        'coefficient': coefficient,
        if (setHelperCoefficient)
          'helper_coefficient': (helperCoefficient == null ||
                  !helperCoefficient.isFinite ||
                  helperCoefficient < 0)
              ? null
              : helperCoefficient,
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