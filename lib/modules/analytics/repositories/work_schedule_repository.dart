import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/day_shift_type.dart';
import '../models/work_schedule_entry.dart';

class WorkScheduleRepository {
  WorkScheduleRepository({SupabaseClient? client})
      : _client = client ?? Supabase.instance.client;

  final SupabaseClient _client;

  /// Загружает график за месяц: employeeId -> day(1..31) -> запись.
  Future<Map<String, Map<int, WorkScheduleEntry>>> loadForMonth(
      DateTime month) async {
    final firstDay = DateTime(month.year, month.month, 1);
    final nextMonthFirst = DateTime(month.year, month.month + 1, 1);
    final List<dynamic> rows = await _client
        .from('work_schedules')
        .select(
            'id, employee_id, work_date, shift_type, arrival_time, departure_time')
        .gte('work_date', _isoDate(firstDay))
        .lt('work_date', _isoDate(nextMonthFirst));

    final result = <String, Map<int, WorkScheduleEntry>>{};
    for (final row in rows) {
      if (row is! Map) continue;
      final entry = WorkScheduleEntry.fromMap(Map<String, dynamic>.from(row));
      result
          .putIfAbsent(entry.employeeId, () => <int, WorkScheduleEntry>{})[
          entry.workDate.day] = entry;
    }
    return result;
  }

  Future<WorkScheduleEntry> upsert({
    required String employeeId,
    required DateTime workDate,
    required DayShiftType shiftType,
    String? arrivalTime,
    String? departureTime,
    String? updatedBy,
  }) async {
    final iso = _isoDate(workDate);
    final result = await _client
        .from('work_schedules')
        .upsert({
          'employee_id': employeeId,
          'work_date': iso,
          'shift_type': shiftTypeToString(shiftType),
          'arrival_time': arrivalTime,
          'departure_time': departureTime,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
          if (updatedBy != null) 'updated_by': updatedBy,
        }, onConflict: 'employee_id,work_date')
        .select()
        .single();
    return WorkScheduleEntry.fromMap(Map<String, dynamic>.from(result));
  }

  static String _isoDate(DateTime dt) {
    final y = dt.year.toString().padLeft(4, '0');
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }
}
