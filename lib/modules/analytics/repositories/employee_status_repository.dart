import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/employee_status.dart';

class EmployeeStatusRepository {
  EmployeeStatusRepository({SupabaseClient? client})
      : _client = client ?? Supabase.instance.client;

  final SupabaseClient _client;

  Future<List<EmployeeStatus>> listAll() async {
    final List<dynamic> rows = await _client
        .from('employee_statuses')
        .select('id, name, description, color')
        .order('name');
    return rows
        .whereType<Map>()
        .map((m) => EmployeeStatus.fromMap(Map<String, dynamic>.from(m)))
        .toList();
  }

  /// Карта employeeId -> statusId, прочитанная из таблицы employees.
  Future<Map<String, String>> loadEmployeeStatusIds() async {
    final List<dynamic> rows =
        await _client.from('employees').select('id, status_id');
    final map = <String, String>{};
    for (final row in rows) {
      if (row is! Map) continue;
      final id = (row['id'] ?? '').toString();
      final statusId = row['status_id']?.toString();
      if (id.isEmpty || statusId == null || statusId.isEmpty) continue;
      map[id] = statusId;
    }
    return map;
  }

  Future<EmployeeStatus> create({
    required String name,
    String? description,
    String? color,
  }) async {
    final result = await _client
        .from('employee_statuses')
        .insert({
          'name': name,
          'description': description,
          'color': color,
        })
        .select()
        .single();
    return EmployeeStatus.fromMap(Map<String, dynamic>.from(result));
  }

  Future<void> delete(String id) async {
    await _client.from('employee_statuses').delete().eq('id', id);
  }

  Future<void> assignToEmployee(String employeeId, String? statusId) async {
    await _client
        .from('employees')
        .update({'status_id': statusId})
        .eq('id', employeeId);
  }

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
}
