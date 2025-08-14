import 'package:supabase_flutter/supabase_flutter.dart';

final _supabase = Supabase.instance.client;

class EmployeeRepository {
  Future<void> addEmployee({
    required String userId,
    required String firstName,
    required String lastName,
    required String patronymic,
    required String iin,
    bool isTechLeader = false,
    List<String> positionIds = const [],
  }) async {
    await _supabase.from('employees').insert({
      'user_id': userId,
      'first_name': firstName,
      'last_name': lastName,
      'patronymic': patronymic,
      'iin': iin,
      'is_tech_leader': isTechLeader,
      'position_ids': positionIds,
    });
  }

  Future<List<Map<String, dynamic>>> fetchEmployees() async {
    final rows = await _supabase
        .from('employees')
        .select()
        .order('created_at', ascending: false);
    return List<Map<String, dynamic>>.from(rows);
  }

  Future<void> updateEmployee(String id, Map<String, dynamic> patch) async {
    await _supabase.from('employees').update(patch).eq('id', id);
  }

  Future<void> deleteEmployee(String id) async {
    await _supabase.from('employees').delete().eq('id', id);
  }
}
