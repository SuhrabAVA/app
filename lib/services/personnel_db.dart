// lib/services/personnel_db.dart
// ASCII-only file to avoid any encoding issues on Windows builds.
import 'package:supabase_flutter/supabase_flutter.dart';

class PersonnelDB {
  final SupabaseClient s;
  PersonnelDB({SupabaseClient? client})
      : s = client ?? Supabase.instance.client;

  // Positions
  Future<List<Map<String, dynamic>>> listPositions() async {
    final data = await s.from('positions').select('*').order('name');
    return List<Map<String, dynamic>>.from(data as List);
  }

  Future<void> insertPosition(
      {required String id, required String name, String? description}) async {
    await s.from('positions').insert({
      'id': id,
      'name': name,
      if (description != null && description.trim().isNotEmpty)
        'description': description.trim(),
    });
  }

  Future<void> updatePosition(
      {required String id, required String name, String? description}) async {
    final payload = <String, dynamic>{
      'name': name,
      'description': (description == null || description.trim().isEmpty)
          ? null
          : description.trim(),
    };
    await s.from('positions').update(payload).eq('id', id);
  }

  Future<void> deletePosition(String id) async {
    await s.from('positions').delete().eq('id', id);
  }

  // Employees
  Future<List<Map<String, dynamic>>> listEmployeesView() async {
    final data = await s.from('employees_view').select('*').order('last_name');
    return List<Map<String, dynamic>>.from(data as List);
  }

  Future<void> insertEmployee({
    required String id,
    required String lastName,
    required String firstName,
    required String patronymic,
    required String iin,
    String? photoUrl,
    required List<String> positionIds,
    bool isFired = false,
    String comments = '',
    String login = '',
    String password = '',
  }) async {
    await s.from('employees').insert({
      'id': id,
      'last_name': lastName,
      'first_name': firstName,
      'patronymic': patronymic,
      'iin': iin,
      'photo_url': photoUrl,
      'is_fired': isFired,
      'comments': comments,
      'login': login,
      'password': password,
    });
    if (positionIds.isNotEmpty) {
      final rows = positionIds
          .map((pid) => {'employee_id': id, 'position_id': pid})
          .toList();
      await s
          .from('employee_positions')
          .upsert(rows, onConflict: 'employee_id,position_id');
    }
  }

  Future<void> updateEmployee({
    required String id,
    String? lastName,
    String? firstName,
    String? patronymic,
    String? iin,
    String? photoUrl,
    bool? isFired,
    String? comments,
    String? login,
    String? password,
    List<String>? positionIds,
  }) async {
    final patch = <String, dynamic>{};
    if (lastName != null) patch['last_name'] = lastName;
    if (firstName != null) patch['first_name'] = firstName;
    if (patronymic != null) patch['patronymic'] = patronymic;
    if (iin != null) patch['iin'] = iin;
    if (photoUrl != null) patch['photo_url'] = photoUrl;
    if (isFired != null) patch['is_fired'] = isFired;
    if (comments != null) patch['comments'] = comments;
    if (login != null) patch['login'] = login;
    if (password != null) patch['password'] = password;
    if (patch.isNotEmpty) {
      await s.from('employees').update(patch).eq('id', id);
    }
    if (positionIds != null) {
      await s.from('employee_positions').delete().eq('employee_id', id);
      if (positionIds.isNotEmpty) {
        final rows = positionIds
            .map((pid) => {'employee_id': id, 'position_id': pid})
            .toList();
        await s.from('employee_positions').insert(rows);
      }
    }
  }

  Future<void> deleteEmployee(String id) async {
    await s.from('employees').delete().eq('id', id);
  }

  // Workplaces
  Future<List<Map<String, dynamic>>> listWorkplacesView() async {
    final data = await s.from('workplaces_view').select('*').order('name');
    return List<Map<String, dynamic>>.from(data as List);
  }

  Future<void> insertWorkplace({
    required String id,
    required String name,
    String? description,
    bool hasMachine = false,
    int maxConcurrentWorkers = 1,
    List<String> positionIds = const [],
  }) async {
    await s.from('workplaces').insert({
      'id': id,
      'name': name,
      'description': (description == null || description.trim().isEmpty)
          ? null
          : description.trim(),
      'has_machine': hasMachine,
      'max_concurrent_workers': maxConcurrentWorkers,
    });
    if (positionIds.isNotEmpty) {
      final rows = positionIds
          .map((pid) => {'workplace_id': id, 'position_id': pid})
          .toList();
      await s
          .from('workplace_positions')
          .upsert(rows, onConflict: 'workplace_id,position_id');
    }
  }

  Future<void> updateWorkplace({
    required String id,
    String? name,
    String? description,
    bool? hasMachine,
    int? maxConcurrentWorkers,
    List<String>? positionIds,
  }) async {
    final patch = <String, dynamic>{};
    if (name != null) patch['name'] = name;
    if (description != null)
      patch['description'] =
          description.trim().isEmpty ? null : description.trim();
    if (hasMachine != null) patch['has_machine'] = hasMachine;
    if (maxConcurrentWorkers != null)
      patch['max_concurrent_workers'] = maxConcurrentWorkers;
    if (patch.isNotEmpty) {
      await s.from('workplaces').update(patch).eq('id', id);
    }
    if (positionIds != null) {
      await s.from('workplace_positions').delete().eq('workplace_id', id);
      if (positionIds.isNotEmpty) {
        final rows = positionIds
            .map((pid) => {'workplace_id': id, 'position_id': pid})
            .toList();
        await s.from('workplace_positions').insert(rows);
      }
    }
  }

  Future<void> deleteWorkplace(String id) async {
    await s.from('workplaces').delete().eq('id', id);
  }

  // Terminals
  Future<List<Map<String, dynamic>>> listTerminalsView() async {
    final data = await s.from('terminals_view').select('*').order('name');
    return List<Map<String, dynamic>>.from(data as List);
  }

  Future<void> insertTerminal({
    required String id,
    required String name,
    String? description,
    List<String> workplaceIds = const [],
  }) async {
    await s.from('terminals').insert({
      'id': id,
      'name': name,
      'description': (description == null || description.trim().isEmpty)
          ? null
          : description.trim(),
    });
    if (workplaceIds.isNotEmpty) {
      final rows = workplaceIds
          .map((wid) => {'terminal_id': id, 'workplace_id': wid})
          .toList();
      await s
          .from('terminal_workplaces')
          .upsert(rows, onConflict: 'terminal_id,workplace_id');
    }
  }

  Future<void> updateTerminal({
    required String id,
    String? name,
    String? description,
    List<String>? workplaceIds,
  }) async {
    final patch = <String, dynamic>{};
    if (name != null) patch['name'] = name;
    if (description != null)
      patch['description'] =
          description.trim().isEmpty ? null : description.trim();
    if (patch.isNotEmpty) {
      await s.from('terminals').update(patch).eq('id', id);
    }
    if (workplaceIds != null) {
      await s.from('terminal_workplaces').delete().eq('terminal_id', id);
      if (workplaceIds.isNotEmpty) {
        final rows = workplaceIds
            .map((wid) => {'terminal_id': id, 'workplace_id': wid})
            .toList();
        await s.from('terminal_workplaces').insert(rows);
      }
    }
  }

  Future<void> deleteTerminal(String id) async {
    await s.from('terminals').delete().eq('id', id);
  }
}
