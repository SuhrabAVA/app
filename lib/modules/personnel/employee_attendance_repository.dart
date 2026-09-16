import 'package:supabase_flutter/supabase_flutter.dart';

import '../../utils/kostanay_time.dart';
import '../../utils/shift_day.dart';

/// Отметка прихода/ухода за один день смены.
class EmployeeAttendanceDay {
  const EmployeeAttendanceDay({
    required this.employeeId,
    required this.workDate,
    this.arrivedAt,
    this.leftAt,
  });

  final String employeeId;
  final DateTime workDate;
  final DateTime? arrivedAt;
  final DateTime? leftAt;

  bool get isOnShift => arrivedAt != null && leftAt == null;

  /// Сколько сотрудник пробыл на смене. null — пока не ушёл или не пришёл.
  Duration? get duration {
    final from = arrivedAt;
    final to = leftAt;
    if (from == null || to == null) return null;
    final value = to.difference(from);
    return value.isNegative ? null : value;
  }

  static EmployeeAttendanceDay fromMap(Map<String, dynamic> map) {
    DateTime? parseTs(dynamic raw) {
      if (raw == null) return null;
      final parsed = DateTime.tryParse(raw.toString());
      // Приход/уход показываем в Костанайском времени (UTC+5), не в зоне
      // устройства.
      return parsed == null ? null : toKostanayTime(parsed);
    }

    return EmployeeAttendanceDay(
      employeeId: (map['employee_id'] ?? '').toString(),
      workDate: DateTime.parse(map['work_date'].toString()),
      arrivedAt: parseTs(map['arrived_at']),
      leftAt: parseTs(map['left_at']),
    );
  }
}

/// Отметки прихода/ухода (`employee_attendance`).
///
/// На начисление не влияют: смена под статусом оплачивается по графику.
/// Отметки нужны, чтобы в аналитике было видно, кто и когда был на смене.
class EmployeeAttendanceRepository {
  EmployeeAttendanceRepository({SupabaseClient? client})
      : _injectedClient = client;

  final SupabaseClient? _injectedClient;

  // Ленивое разрешение клиента: репозиторий создаётся в полях виджетов.
  late final SupabaseClient _client =
      _injectedClient ?? Supabase.instance.client;

  static const _table = 'employee_attendance';
  static const _columns = 'employee_id, work_date, arrived_at, left_at';

  /// Отметка «Пришёл». Повторное нажатие не сдвигает время: первый приход —
  /// он и есть приход, иначе выход и повторный вход затирали бы начало смены.
  Future<void> markArrival({
    required String employeeId,
    DateTime? at,
  }) async {
    final moment = at ?? DateTime.now();
    final existing = await loadDay(
      employeeId: employeeId,
      workDate: shiftDayOf(moment),
    );
    if (existing?.arrivedAt != null && existing?.leftAt == null) return;

    await _client.from(_table).upsert(
      {
        'employee_id': employeeId,
        'work_date': _isoDate(shiftDayOf(moment)),
        'arrived_at': moment.toUtc().toIso8601String(),
        'left_at': null,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      },
      onConflict: 'employee_id,work_date',
    );
  }

  /// Отметка «Ушёл». Если прихода не было, он проставляется тем же моментом:
  /// строка без прихода читалась бы как «на смене» и висела бы вечно.
  Future<void> markDeparture({
    required String employeeId,
    DateTime? at,
  }) async {
    final moment = at ?? DateTime.now();
    final workDate = shiftDayOf(moment);
    final existing = await loadDay(employeeId: employeeId, workDate: workDate);
    final arrival = existing?.arrivedAt ?? moment;

    await _client.from(_table).upsert(
      {
        'employee_id': employeeId,
        'work_date': _isoDate(workDate),
        'arrived_at': arrival.toUtc().toIso8601String(),
        'left_at': moment.toUtc().toIso8601String(),
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      },
      onConflict: 'employee_id,work_date',
    );
  }

  Future<EmployeeAttendanceDay?> loadDay({
    required String employeeId,
    required DateTime workDate,
  }) async {
    final row = await _client
        .from(_table)
        .select(_columns)
        .eq('employee_id', employeeId)
        .eq('work_date', _isoDate(workDate))
        .maybeSingle();
    if (row == null) return null;
    return EmployeeAttendanceDay.fromMap(Map<String, dynamic>.from(row));
  }

  /// Отметки за месяц: employeeId → день месяца → отметка.
  Future<Map<String, Map<int, EmployeeAttendanceDay>>> loadForMonth(
    DateTime month,
  ) async {
    final first = DateTime(month.year, month.month, 1);
    final nextMonth = DateTime(month.year, month.month + 1, 1);

    final rows = await _client
        .from(_table)
        .select(_columns)
        .gte('work_date', _isoDate(first))
        .lt('work_date', _isoDate(nextMonth));

    final result = <String, Map<int, EmployeeAttendanceDay>>{};
    for (final row in (rows as List)) {
      if (row is! Map) continue;
      final parsed =
          EmployeeAttendanceDay.fromMap(Map<String, dynamic>.from(row));
      if (parsed.employeeId.isEmpty) continue;
      result.putIfAbsent(parsed.employeeId, () => {})[parsed.workDate.day] =
          parsed;
    }
    return result;
  }

  static String _isoDate(DateTime dt) {
    final y = dt.year.toString().padLeft(4, '0');
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }
}
