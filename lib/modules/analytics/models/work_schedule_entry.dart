import 'day_shift_type.dart';

class WorkScheduleEntry {
  final String id;
  final String employeeId;
  final DateTime workDate;
  final DayShiftType shiftType;
  final String? arrivalTime;   // "HH:MM"
  final String? departureTime; // "HH:MM"

  const WorkScheduleEntry({
    required this.id,
    required this.employeeId,
    required this.workDate,
    required this.shiftType,
    this.arrivalTime,
    this.departureTime,
  });

  factory WorkScheduleEntry.fromMap(Map<String, dynamic> map) {
    DateTime parseDate(dynamic v) {
      if (v is DateTime) return v;
      if (v is String) return DateTime.parse(v);
      throw ArgumentError('Bad work_date: $v');
    }

    String? parseTime(dynamic v) {
      if (v == null) return null;
      final str = v.toString();
      if (str.isEmpty) return null;
      // Supabase returns "HH:MM:SS" — обрезаем до HH:MM.
      if (str.length >= 5) return str.substring(0, 5);
      return str;
    }

    return WorkScheduleEntry(
      id: (map['id'] ?? '').toString(),
      employeeId: (map['employee_id'] ?? '').toString(),
      workDate: parseDate(map['work_date']),
      shiftType: parseShiftType(map['shift_type'] as String?),
      arrivalTime: parseTime(map['arrival_time']),
      departureTime: parseTime(map['departure_time']),
    );
  }

  Map<String, dynamic> toUpsertMap() => {
        'employee_id': employeeId,
        'work_date':
            '${workDate.year.toString().padLeft(4, '0')}-${workDate.month.toString().padLeft(2, '0')}-${workDate.day.toString().padLeft(2, '0')}',
        'shift_type': shiftTypeToString(shiftType),
        'arrival_time': arrivalTime,
        'departure_time': departureTime,
      };

  WorkScheduleEntry copyWith({
    DayShiftType? shiftType,
    String? arrivalTime,
    String? departureTime,
  }) =>
      WorkScheduleEntry(
        id: id,
        employeeId: employeeId,
        workDate: workDate,
        shiftType: shiftType ?? this.shiftType,
        arrivalTime: arrivalTime ?? this.arrivalTime,
        departureTime: departureTime ?? this.departureTime,
      );

  /// Возвращает дефолтное время прихода/ухода для типа смены.
  static (String?, String?) defaultsFor(DayShiftType type) {
    switch (type) {
      case DayShiftType.day:
        return ('08:00', '20:00');
      case DayShiftType.night:
        return ('20:00', '08:00');
      case DayShiftType.off:
        return (null, null);
    }
  }
}
