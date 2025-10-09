import 'package:supabase_flutter/supabase_flutter.dart';
import '../services/doc_db.dart';
final _supabase = Supabase.instance.client;
final _docDb = DocDB();
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
    await _docDb.insert('employees', {
      'userId': userId,
      'firstName': firstName,
      'lastName': lastName,
      'patronymic': patronymic,
      'iin': iin,
      'isTechLeader': isTechLeader,
      'positionIds': positionIds,
    });
  }

  Future<List<Map<String, dynamic>>> fetchEmployees() async {
    final rows = await _docDb.list('employees');
    return rows
        .map((row) {
          final data = Map<String, dynamic>.from(row['data'] ?? {});
          data['id'] = row['id'];
          return data;
        })
        .toList();
  }

  Future<void> updateEmployee(String id, Map<String, dynamic> patch) async {
    await _docDb.patchById(id, patch);
  }

  Future<void> deleteEmployee(String id) async {
    await _docDb.deleteById(id);
  }
}
