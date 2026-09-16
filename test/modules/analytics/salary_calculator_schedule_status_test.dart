import 'package:flutter_test/flutter_test.dart';
import 'package:sheet_clone/modules/analytics/calculators/salary_calculator.dart';
import 'package:sheet_clone/modules/analytics/models/analytics_event.dart';
import 'package:sheet_clone/modules/analytics/models/analytics_month.dart';
import 'package:sheet_clone/modules/analytics/models/day_shift_type.dart';
import 'package:sheet_clone/modules/analytics/models/employee_status_period.dart';
import 'package:sheet_clone/modules/analytics/models/salary_adjustments.dart';
import 'package:sheet_clone/modules/analytics/models/salary_settings.dart';
import 'package:sheet_clone/modules/analytics/utils/analytics_constants.dart';

/// Смена под статусом оплачивается по графику: фиксированная ставка за смену,
/// а не за часы. Уборщик и охранник заданий не выполняют вовсе — по событиям
/// им нечего было бы засчитать.
AnalyticsEvent _work(String id, int day, {required int hours, double qty = 0}) {
  return AnalyticsEvent(
    id: id,
    type: AnalyticsEventType.work,
    startTime: DateTime(2026, 6, day, 8),
    endTime: DateTime(2026, 6, day, 8 + hours),
    employeeId: 'e1',
    workplaceId: 'wp1',
    taskId: 'task-$id',
    orderId: 'order-$id',
    qty: qty,
  );
}

void main() {
  final month = AnalyticsMonth.fromYearMonth(2026, 6);
  final settings = SalarySettings.defaults(month.firstDay);
  final adjustments = SalaryAdjustments.zero('e1', month.firstDay);

  final wholeMonthStatus = [
    EmployeeStatusPeriod(statusId: 's1', dateFrom: DateTime(2026, 6, 1)),
  ];

  SalaryBreakdown compute({
    List<AnalyticsEvent> events = const [],
    Map<int, DayShiftType> scheduledShifts = const {},
  }) {
    return SalaryCalculator.compute(
      events: events,
      coefficients: const {'wp1': 0.5},
      settings: settings,
      adjustments: adjustments,
      halfShiftMinutes: AnalyticsConstants.halfShiftMinutes,
      month: month,
      statusPeriods: wholeMonthStatus,
      statusPayRates: const {'s1': 8000},
      statusNames: const {'s1': 'Охранник'},
      scheduledShifts: scheduledShifts,
    );
  }

  test('сотрудник без единого задания получает по графику', () {
    final breakdown = compute(
      scheduledShifts: const {
        1: DayShiftType.day,
        2: DayShiftType.day,
        3: DayShiftType.off,
        4: DayShiftType.night,
      },
    );

    expect(breakdown.statusShiftsTotal, 3);
    expect(breakdown.dayShifts, 2);
    expect(breakdown.nightShifts, 1);
    expect(breakdown.fixedStatusPay, 24000);
    expect(breakdown.accrued, 24000);
    expect(breakdown.statusPayBreakdown.single.statusName, 'Охранник');
  });

  test('выходной по графику не оплачивается', () {
    final breakdown = compute(
      scheduledShifts: const {1: DayShiftType.off, 2: DayShiftType.off},
    );

    expect(breakdown.statusShiftsTotal, 0);
    expect(breakdown.fixedStatusPay, 0);
  });

  test('смена засчитывается целиком, даже если отработан час', () {
    final breakdown = compute(
      events: [_work('short', 1, hours: 1)],
      scheduledShifts: const {1: DayShiftType.day},
    );

    expect(breakdown.statusShiftsTotal, 1);
    expect(breakdown.fixedStatusPay, 8000);
  });

  test('без графика остаётся прежнее правило «не менее полсмены»', () {
    final short = compute(events: [_work('short', 1, hours: 1)]);
    expect(short.statusShiftsTotal, 0, reason: 'час работы — не смена');

    final full = compute(events: [_work('full', 1, hours: 8)]);
    expect(full.statusShiftsTotal, 1);
    expect(full.fixedStatusPay, 8000);
  });

  test('выход в графический выходной оплачивается по событиям', () {
    final breakdown = compute(
      events: [_work('extra', 5, hours: 8)],
      scheduledShifts: const {5: DayShiftType.off},
    );

    expect(breakdown.statusShiftsTotal, 1);
    expect(breakdown.fixedStatusPay, 8000);
  });

  test('под статусом сдельная не начисляется, график её не включает', () {
    final breakdown = compute(
      events: [_work('w', 1, hours: 8, qty: 1000)],
      scheduledShifts: const {1: DayShiftType.day},
    );

    expect(breakdown.pieceSalary, 0, reason: 'дни под статусом вне сдельной');
    expect(breakdown.fixedStatusPay, 8000);
  });

  test('график сотрудника без статуса ничего не меняет', () {
    final breakdown = SalaryCalculator.compute(
      events: [_work('w', 1, hours: 8, qty: 1000)],
      coefficients: const {'wp1': 0.5},
      settings: settings,
      adjustments: adjustments,
      halfShiftMinutes: AnalyticsConstants.halfShiftMinutes,
      month: month,
      scheduledShifts: const {1: DayShiftType.day, 2: DayShiftType.day},
    );

    expect(breakdown.statusShiftsTotal, 0);
    expect(breakdown.shiftsTotal, 1, reason: 'смены считаются по событиям');
    expect(breakdown.pieceSalary, 500);
  });
}
