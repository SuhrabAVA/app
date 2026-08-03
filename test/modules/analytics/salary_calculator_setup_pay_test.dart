import 'package:flutter_test/flutter_test.dart';
import 'package:sheet_clone/modules/analytics/calculators/salary_calculator.dart';
import 'package:sheet_clone/modules/analytics/models/analytics_event.dart';
import 'package:sheet_clone/modules/analytics/models/analytics_month.dart';
import 'package:sheet_clone/modules/analytics/models/salary_adjustments.dart';
import 'package:sheet_clone/modules/analytics/models/salary_settings.dart';
import 'package:sheet_clone/modules/analytics/utils/analytics_constants.dart';

AnalyticsEvent _event(
  String id,
  int day,
  AnalyticsEventType type, {
  String workplaceId = 'wp1',
  double qty = 0,
  double setupQty = 0,
}) {
  final start = DateTime(2026, 6, day, 8);
  final end = DateTime(2026, 6, day, 16);
  return AnalyticsEvent(
    id: id,
    type: type,
    startTime: start,
    endTime: end,
    employeeId: 'e1',
    workplaceId: workplaceId,
    taskId: 'task-$id',
    orderId: 'order-$id',
    qty: qty,
    setupQty: setupQty,
  );
}

void main() {
  final month = AnalyticsMonth.fromYearMonth(2026, 6);
  final settings = SalarySettings.defaults(month.firstDay);
  final adjustments = SalaryAdjustments.zero('e1', month.firstDay);
  const coefficients = {'wp1': 0.5};

  test('оплата приладки = кол-во приладок × цена рабочего места, входит в итог', () {
    final events = [
      _event('w1', 1, AnalyticsEventType.work, qty: 1000),
      // 3 приладки по 500 ₸ на wp1 и 2 приладки на wp2 по 700 ₸.
      _event('s1', 1, AnalyticsEventType.setup, setupQty: 3),
      _event('s2', 2, AnalyticsEventType.setup,
          workplaceId: 'wp2', setupQty: 2),
    ];

    final breakdown = SalaryCalculator.compute(
      events: events,
      coefficients: coefficients,
      settings: settings,
      adjustments: adjustments,
      halfShiftMinutes: AnalyticsConstants.halfShiftMinutes,
      month: month,
      setupPrices: const {'wp1': 500, 'wp2': 700},
    );

    expect(breakdown.setupPayQty, 5);
    expect(breakdown.setupPay, 3 * 500 + 2 * 700); // 2900
    expect(breakdown.accrued, breakdown.pieceSalary + breakdown.setupPay);
  });

  test('рабочее место без цены (или без приладки) не даёт оплату приладки', () {
    final events = [
      _event('s1', 1, AnalyticsEventType.setup, setupQty: 4),
    ];

    final breakdown = SalaryCalculator.compute(
      events: events,
      coefficients: coefficients,
      settings: settings,
      adjustments: adjustments,
      halfShiftMinutes: AnalyticsConstants.halfShiftMinutes,
      month: month,
      setupPrices: const {}, // цены не заданы
    );

    expect(breakdown.setupPay, 0);
    expect(breakdown.setupPayQty, 0);
  });

  test('setupQty = 0 (размеры совпали, режим by_size) не даёт оплату', () {
    final events = [
      _event('s1', 1, AnalyticsEventType.setup, setupQty: 0),
    ];

    final breakdown = SalaryCalculator.compute(
      events: events,
      coefficients: coefficients,
      settings: settings,
      adjustments: adjustments,
      halfShiftMinutes: AnalyticsConstants.halfShiftMinutes,
      month: month,
      setupPrices: const {'wp1': 500},
    );

    expect(breakdown.setupPay, 0);
    expect(breakdown.setupPayQty, 0);
  });

  test('обратная совместимость: без setupPrices расчёт не меняется', () {
    final events = [
      _event('w1', 1, AnalyticsEventType.work, qty: 1000),
      _event('s1', 1, AnalyticsEventType.setup, setupQty: 2),
    ];

    final withParam = SalaryCalculator.compute(
      events: events,
      coefficients: coefficients,
      settings: settings,
      adjustments: adjustments,
      halfShiftMinutes: AnalyticsConstants.halfShiftMinutes,
      month: month,
      setupPrices: const {},
    );
    final withoutParam = SalaryCalculator.compute(
      events: events,
      coefficients: coefficients,
      settings: settings,
      adjustments: adjustments,
      halfShiftMinutes: AnalyticsConstants.halfShiftMinutes,
      month: month,
    );

    expect(withParam.setupPay, 0);
    expect(withParam.accrued, withoutParam.accrued);
    expect(withParam.total, withoutParam.total);
  });
}
