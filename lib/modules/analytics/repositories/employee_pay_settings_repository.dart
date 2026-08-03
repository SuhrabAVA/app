import 'package:supabase_flutter/supabase_flutter.dart';

/// Тип оплаты и оклад за смену сотрудника (employees.pay_type,
/// employees.base_day_salary). Финансовые данные, не связанные со
/// статусами — вынесены из бывшего EmployeeStatusRepository, который
/// переехал в модуль персонала.
class EmployeePaySettingsRepository {
  EmployeePaySettingsRepository({SupabaseClient? client})
      : _client = client ?? Supabase.instance.client;

  final SupabaseClient _client;

  Future<Map<String, String?>> loadEmployeePayTypes() async {
    final List<dynamic> rows =
        await _client.from('employees').select('id, pay_type');
    final result = <String, String?>{};
    for (final row in rows) {
      if (row is! Map) continue;
      final id = (row['id'] ?? '').toString();
      if (id.isEmpty) continue;
      result[id] = row['pay_type']?.toString();
    }
    return result;
  }

  Future<void> setPayType(String employeeId, String? payType) async {
    await _client
        .from('employees')
        .update({'pay_type': payType})
        .eq('id', employeeId);
  }

  /// Оклады за смену: employeeId -> base_day_salary. Грузим напрямую из
  /// таблицы employees (view employees_view эту колонку не отдаёт).
  Future<Map<String, double>> loadEmployeeBaseSalaries() async {
    final List<dynamic> rows =
        await _client.from('employees').select('id, base_day_salary');
    final result = <String, double>{};
    for (final row in rows) {
      if (row is! Map) continue;
      final id = (row['id'] ?? '').toString();
      if (id.isEmpty) continue;
      final v = row['base_day_salary'];
      result[id] = v is num
          ? v.toDouble()
          : double.tryParse(v?.toString() ?? '') ?? 0;
    }
    return result;
  }

  Future<void> setBaseDaySalary(String employeeId, double value) async {
    await _client
        .from('employees')
        .update({'base_day_salary': value})
        .eq('id', employeeId);
  }
}
