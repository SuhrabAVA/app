import 'package:supabase_flutter/supabase_flutter.dart';

import '../../utils/shift_day.dart';
import 'employee_status_model.dart';

/// Статусы сотрудников: справочник + история присвоения с датами.
/// Текущий статус сотрудника = строка employee_status_history с
/// date_to is null. Владелец — модуль персонала (аналитика читает отсюда,
/// не пишет).
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

  Future<EmployeeStatus> update({
    required String id,
    required String name,
    String? description,
    String? color,
  }) async {
    final result = await _client
        .from('employee_statuses')
        .update({
          'name': name,
          'description': description,
          'color': color,
        })
        .eq('id', id)
        .select()
        .single();
    return EmployeeStatus.fromMap(Map<String, dynamic>.from(result));
  }

  Future<void> delete(String id) async {
    await _client.from('employee_statuses').delete().eq('id', id);
  }

  /// Карта employeeId -> statusId для ТЕКУЩИХ (открытых) периодов.
  Future<Map<String, String>> loadCurrentStatusIds() async {
    final List<dynamic> rows = await _client
        .from('employee_status_history')
        .select('employee_id, status_id')
        .filter('date_to', 'is', null);
    final map = <String, String>{};
    for (final row in rows) {
      if (row is! Map) continue;
      final employeeId = (row['employee_id'] ?? '').toString();
      final statusId = (row['status_id'] ?? '').toString();
      if (employeeId.isEmpty || statusId.isEmpty) continue;
      map[employeeId] = statusId;
    }
    return map;
  }

  /// Все периоды (по всем сотрудникам), пересекающие месяц, заданный первым
  /// числом [monthFirstDay]. Не зависит от типа AnalyticsMonth (модуль
  /// персонала не импортирует аналитику) — принимает голый DateTime.
  Future<Map<String, List<EmployeeStatusHistoryRow>>> loadHistoryForMonth(
      DateTime monthFirstDay) async {
    final nextMonthFirstDay =
        DateTime(monthFirstDay.year, monthFirstDay.month + 1, 1);
    final isoNextFirst = _isoDate(nextMonthFirstDay);
    final isoFirst = _isoDate(monthFirstDay);
    // date_from < nextMonthFirstDay AND (date_to is null OR date_to > firstDay)
    final List<dynamic> rows = await _client
        .from('employee_status_history')
        .select('id, employee_id, status_id, date_from, date_to')
        .lt('date_from', isoNextFirst)
        .or('date_to.is.null,date_to.gt.$isoFirst');
    final result = <String, List<EmployeeStatusHistoryRow>>{};
    for (final row in rows) {
      if (row is! Map) continue;
      final parsed =
          EmployeeStatusHistoryRow.fromMap(Map<String, dynamic>.from(row));
      if (parsed.employeeId.isEmpty) continue;
      result.putIfAbsent(parsed.employeeId, () => []).add(parsed);
    }
    return result;
  }

  Future<void> openPeriod({
    required String employeeId,
    required String statusId,
    DateTime? from,
  }) async {
    await _client.from('employee_status_history').insert({
      'employee_id': employeeId,
      'status_id': statusId,
      'date_from': _isoDate(from ?? DateTime.now()),
    });
  }

  Future<void> closeOpenPeriod({
    required String employeeId,
    DateTime? to,
  }) async {
    await _client
        .from('employee_status_history')
        .update({'date_to': _isoDate(to ?? DateTime.now())})
        .eq('employee_id', employeeId)
        .filter('date_to', 'is', null);
  }

  /// Присваивает статус сотруднику (или снимает, если [statusId] == null),
  /// с сохранением истории: закрывает текущий открытый период (если есть)
  /// и открывает новый (если [statusId] задан).
  ///
  /// Граница — начало СЛЕДУЮЩЕЙ смены, а не текущий день. Раньше оба
  /// периода резались сегодняшним числом, и снятие статуса в середине смены
  /// задним числом переводило уже отработанную часть дня на другую оплату:
  /// стажёр, у которого статус сняли в обед, получал за это утро сдельно.
  /// Текущий день смены целиком остаётся за прежним состоянием (date_to
  /// исключительна), новое начинается со следующего дня — см. [shiftDayOf]:
  /// правка после полуночи, но до 06:00, относится к текущей ночной смене.
  Future<void> assignStatus({
    required String employeeId,
    required String? statusId,
    DateTime? now,
  }) async {
    final boundary = nextShiftDayAfter(now ?? DateTime.now());
    await closeOpenPeriod(employeeId: employeeId, to: boundary);
    if (statusId != null && statusId.isNotEmpty) {
      await openPeriod(
        employeeId: employeeId,
        statusId: statusId,
        from: boundary,
      );
    }
  }

  static String _isoDate(DateTime dt) {
    final y = dt.year.toString().padLeft(4, '0');
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }
}
