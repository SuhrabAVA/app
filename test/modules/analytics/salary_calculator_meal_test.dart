import 'package:flutter_test/flutter_test.dart';
import 'package:sheet_clone/modules/analytics/calculators/salary_calculator.dart';
import 'package:sheet_clone/modules/analytics/models/analytics_event.dart';
import 'package:sheet_clone/modules/analytics/models/analytics_month.dart';
import 'package:sheet_clone/modules/analytics/models/salary_adjustments.dart';
import 'package:sheet_clone/modules/analytics/models/salary_settings.dart';
import 'package:sheet_clone/modules/analytics/utils/analytics_constants.dart';

AnalyticsEvent _work(String id, int day, {double qty = 1000}) {
  return AnalyticsEvent(
    id: id,
    type: AnalyticsEventType.work,
    startTime: DateTime(2026, 6, day, 8),
    endTime: DateTime(2026, 6, day, 16),
    employeeId: 'e1',
    workplaceId: 'wp1',
    taskId: 'task-$id',
    orderId: 'order-$id',
    qty: qty,
  );
}

void main() {
  final month = AnalyticsMonth.fromYearMonth(2026, 6);
  final adjustments = SalaryAdjustments.zero('e1', month.firstDay);
  const coefficients = {'wp1': 0.5};

  final events = [_work('w1', 1), _work('w2', 2), _work('w3', 3)];

  SalaryBreakdown computeWithMeal(double mealAmount) {
    return SalaryCalculator.compute(
      events: events,
      coefficients: coefficients,
      settings: SalarySettings.defaults(month.firstDay)
          .copyWith(mealAmount: mealAmount),
      adjustments: adjustments,
      halfShiftMinutes: AnalyticsConstants.halfShiftMinutes,
      month: month,
    );
  }

  group('питание за счёт компании', () {
    test('не уменьшает итоговую зарплату', () {
      final withoutMeal = computeWithMeal(0);
      final withMeal = computeWithMeal(1500);

      expect(withMeal.mealDeduction, 1500 * withMeal.shiftsTotal,
          reason: 'расход компании считается как смены × цена порции');
      expect(withMeal.total, withoutMeal.total,
          reason: 'питание не удерживается с сотрудника');
    });

    test('итог = начислено минус прочие удержания, без питания', () {
      final brk = computeWithMeal(2000);

      expect(brk.mealDeduction, greaterThan(0));
      expect(brk.total, brk.accrued);
    });

    test('прочие удержания по-прежнему вычитаются', () {
      final brk = SalaryCalculator.compute(
        events: events,
        coefficients: coefficients,
        settings: SalarySettings.defaults(month.firstDay)
            .copyWith(mealAmount: 1500),
        adjustments: adjustments.copyWith(advance: 10000, social: 5000),
        halfShiftMinutes: AnalyticsConstants.halfShiftMinutes,
        month: month,
      );

      expect(brk.total, brk.accrued - 15000);
    });
  });
}
