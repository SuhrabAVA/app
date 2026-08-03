import 'package:flutter_test/flutter_test.dart';
import 'package:sheet_clone/modules/analytics/calculators/salary_calculator.dart';
import 'package:sheet_clone/modules/analytics/models/analytics_event.dart';
import 'package:sheet_clone/modules/analytics/models/analytics_month.dart';
import 'package:sheet_clone/modules/analytics/models/employee_status_period.dart';
import 'package:sheet_clone/modules/analytics/models/salary_adjustments.dart';
import 'package:sheet_clone/modules/analytics/models/salary_settings.dart';
import 'package:sheet_clone/modules/analytics/utils/analytics_constants.dart';

AnalyticsEvent _workEvent(String id, int day, double qty) {
  final start = DateTime(2026, 6, day, 8);
  final end = DateTime(2026, 6, day, 16); // 8h — well above halfShiftMinutes
  return AnalyticsEvent(
    id: id,
    type: AnalyticsEventType.work,
    startTime: start,
    endTime: end,
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
  const coefficients = {'wp1': 0.5};

  test('контрольный пример: стажёр 6 смен/300000шт (не оплачено) + сдельно 8 смен/250000шт = 185000', () {
    // Дни 1-14: статус "стажер" активен, 6 смен, 300 000 шт (сдельно НЕ платится).
    final statusEvents = [
      for (var d = 1; d <= 6; d++) _workEvent('status-$d', d, 50000),
    ];
    // Дни 15-31: без статуса, 8 смен, 250 000 шт (сдельно как обычно).
    final normalEvents = [
      for (var d = 15; d <= 22; d++) _workEvent('normal-$d', d, 31250),
    ];

    final breakdown = SalaryCalculator.compute(
      events: [...statusEvents, ...normalEvents],
      coefficients: coefficients,
      settings: settings,
      adjustments: adjustments,
      halfShiftMinutes: AnalyticsConstants.halfShiftMinutes,
      month: month,
      statusPeriods: [
        EmployeeStatusPeriod(
          statusId: 's1',
          dateFrom: DateTime(2026, 6, 1),
          dateTo: DateTime(2026, 6, 15),
        ),
      ],
      statusPayRates: const {'s1': 10000},
      statusNames: const {'s1': 'Стажер'},
    );

    expect(breakdown.pieceSalary, 125000);
    expect(breakdown.fixedStatusPay, 60000);
    expect(breakdown.statusShiftsTotal, 6);
    expect(breakdown.statusPayBreakdown, hasLength(1));
    expect(breakdown.statusPayBreakdown.single.shifts, 6);
    expect(breakdown.statusPayBreakdown.single.amount, 60000);
    expect(breakdown.accrued, 185000);
    expect(breakdown.total, 185000);
  });

  test('без истории статусов — расчёт идентичен обычному (обратная совместимость)', () {
    final events = [
      for (var d = 1; d <= 8; d++) _workEvent('e-$d', d, 1000),
    ];

    final withEmptyStatus = SalaryCalculator.compute(
      events: events,
      coefficients: coefficients,
      settings: settings,
      adjustments: adjustments,
      halfShiftMinutes: AnalyticsConstants.halfShiftMinutes,
      month: month,
      statusPeriods: const [],
      statusPayRates: const {},
      statusNames: const {},
    );
    final withoutStatusParams = SalaryCalculator.compute(
      events: events,
      coefficients: coefficients,
      settings: settings,
      adjustments: adjustments,
      halfShiftMinutes: AnalyticsConstants.halfShiftMinutes,
    );

    expect(withEmptyStatus.pieceSalary, withoutStatusParams.pieceSalary);
    expect(withEmptyStatus.shiftsTotal, withoutStatusParams.shiftsTotal);
    expect(withEmptyStatus.averageShiftSalary, withoutStatusParams.averageShiftSalary);
    expect(withEmptyStatus.accrued, withoutStatusParams.accrued);
    expect(withEmptyStatus.total, withoutStatusParams.total);
    expect(withEmptyStatus.fixedStatusPay, 0);
  });

  test('статус без настроенной ставки (0) не влияет на оплату', () {
    final events = [
      for (var d = 1; d <= 6; d++) _workEvent('e-$d', d, 50000),
    ];

    final breakdown = SalaryCalculator.compute(
      events: events,
      coefficients: coefficients,
      settings: settings,
      adjustments: adjustments,
      halfShiftMinutes: AnalyticsConstants.halfShiftMinutes,
      month: month,
      statusPeriods: [
        EmployeeStatusPeriod(
          statusId: 's1',
          dateFrom: DateTime(2026, 6, 1),
          dateTo: DateTime(2026, 6, 15),
        ),
      ],
      statusPayRates: const {'s1': 0}, // ставка не настроена
      statusNames: const {'s1': 'Стажер'},
    );

    // Ставка 0 -> статус игнорируется, платим сдельно как обычно.
    expect(breakdown.fixedStatusPay, 0);
    expect(breakdown.pieceSalary, 300000 * 0.5);
    expect(breakdown.total, 300000 * 0.5);
  });
}
