import '../models/analytics_event.dart';
import 'analytics_calculator.dart';

class EmployeeRatingRow {
  final String employeeId;
  final int usefulMinutes;
  final double qty;
  final double minutesPerUnit;
  final double speed;

  const EmployeeRatingRow({
    required this.employeeId,
    required this.usefulMinutes,
    required this.qty,
    required this.minutesPerUnit,
    required this.speed,
  });
}

class RatingCalculator {
  RatingCalculator._();

  /// Строит рейтинг сотрудников на рабочем месте по событиям месяца.
  /// Сортировка по убыванию скорости (qty / минута).
  /// В рейтинг включаются только сотрудники с qty > 0.
  static List<EmployeeRatingRow> buildForWorkplace({
    required List<AnalyticsEvent> eventsForWorkplace,
  }) {
    final byEmployee = <String, List<AnalyticsEvent>>{};
    for (final e in eventsForWorkplace) {
      byEmployee.putIfAbsent(e.employeeId, () => []).add(e);
    }

    final rows = <EmployeeRatingRow>[];
    byEmployee.forEach((employeeId, events) {
      final qty = AnalyticsCalculator.totalQty(events);
      if (qty <= 0) return;
      final minutes = AnalyticsCalculator.usefulMinutes(events);
      final mpu = qty > 0 ? minutes / qty : 0.0;
      final speed = minutes > 0 ? qty / minutes : 0.0;
      rows.add(EmployeeRatingRow(
        employeeId: employeeId,
        usefulMinutes: minutes,
        qty: qty,
        minutesPerUnit: mpu,
        speed: speed,
      ));
    });

    rows.sort((a, b) => b.speed.compareTo(a.speed));
    return rows;
  }
}
