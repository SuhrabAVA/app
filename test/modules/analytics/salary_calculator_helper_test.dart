import 'package:flutter_test/flutter_test.dart';
import 'package:sheet_clone/modules/analytics/calculators/salary_calculator.dart';
import 'package:sheet_clone/modules/analytics/models/analytics_event.dart';
import 'package:sheet_clone/modules/analytics/models/workplace_coefficient.dart';

/// Совместная работа: количество в событии уже персональное (доля по времени
/// либо полный тираж на станке), а разницу в оплате делает СВОЯ ставка
/// помощника. Раньше вместо ставки был процент скидки от основной —
/// он привязывал одну цену к другой, хотя ответственность основного
/// исполнителя выше не на ровную долю.
AnalyticsEvent _work({required double qty, bool helper = false}) {
  return AnalyticsEvent(
    id: helper ? 'helper' : 'main',
    type: AnalyticsEventType.work,
    startTime: DateTime(2026, 6, 3, 8),
    endTime: DateTime(2026, 6, 3, 16),
    employeeId: helper ? 'e2' : 'e1',
    workplaceId: 'wp1',
    taskId: 'task-1',
    orderId: 'order-1',
    qty: qty,
    isHelper: helper,
  );
}

void main() {
  const coefficients = {'wp1': 2.0};

  group('helperCoefficientOrMain', () {
    test('своя ставка используется как есть', () {
      expect(helperCoefficientOrMain(1.5, 2), 1.5);
    });

    test('без своей ставки платим по основной', () {
      expect(helperCoefficientOrMain(null, 2), 2);
    });

    test('ноль — это «помощнику не платим», а не «нет настройки»', () {
      // Отличие от null принципиальное: ноль вводит человек осознанно.
      expect(helperCoefficientOrMain(0, 2), 0);
    });

    test('мусор и минус не проходят', () {
      expect(helperCoefficientOrMain(-5, 2), 2,
          reason: 'сдельная не уходит в минус');
      expect(helperCoefficientOrMain(double.nan, 2), 2);
      expect(helperCoefficientOrMain(double.infinity, 2), 2);
    });

    test('битая основная ставка не превращается в отрицательную оплату', () {
      expect(helperCoefficientOrMain(null, double.nan), 0);
      expect(helperCoefficientOrMain(null, -3), 0);
    });
  });

  group('piecewise', () {
    test('основной по своей ставке, помощник по своей', () {
      // 6000 засчитано каждому; основной 2 ₸/шт, помощник 1.6 ₸/шт.
      final main = SalaryCalculator.piecewise(
        workEvents: [_work(qty: 6000)],
        workplaceCoefficients: coefficients,
        helperCoefficients: const {'wp1': 1.6},
      );
      final helper = SalaryCalculator.piecewise(
        workEvents: [_work(qty: 6000, helper: true)],
        workplaceCoefficients: coefficients,
        helperCoefficients: const {'wp1': 1.6},
      );

      expect(main, 12000);
      expect(helper, 9600);
    });

    test('без настройки помощник получает наравне', () {
      final helper = SalaryCalculator.piecewise(
        workEvents: [_work(qty: 6000, helper: true)],
        workplaceCoefficients: coefficients,
      );
      expect(helper, 12000);
    });

    test('ставка действует только на своё рабочее место', () {
      final helper = SalaryCalculator.piecewise(
        workEvents: [_work(qty: 6000, helper: true)],
        workplaceCoefficients: coefficients,
        helperCoefficients: const {'wp-other': 0.5},
      );
      expect(helper, 12000, reason: 'настройка чужого места не применяется');
    });

    test('нулевая ставка оставляет помощника без сдельной', () {
      final helper = SalaryCalculator.piecewise(
        workEvents: [_work(qty: 6000, helper: true)],
        workplaceCoefficients: coefficients,
        helperCoefficients: const {'wp1': 0},
      );
      expect(helper, 0);
    });

    test('ставка помощника выше основной применяется как задано', () {
      // Ограничения «не больше основного» больше нет: две цены независимы,
      // и запрет был бы домыслом за руководителя.
      final helper = SalaryCalculator.piecewise(
        workEvents: [_work(qty: 1000, helper: true)],
        workplaceCoefficients: coefficients,
        helperCoefficients: const {'wp1': 3},
      );
      expect(helper, 3000);
    });

    test('смешанная смена: свои этапы по основной, чужие по помощничьей', () {
      final sum = SalaryCalculator.piecewise(
        workEvents: [
          _work(qty: 1000),
          _work(qty: 1000, helper: true),
        ],
        workplaceCoefficients: coefficients,
        helperCoefficients: const {'wp1': 1.6},
      );
      // 1000×2 + 1000×1.6
      expect(sum, 3600);
    });
  });

  group('WorkplaceCoefficient', () {
    test('читает helper_coefficient из строки БД', () {
      final model = WorkplaceCoefficient.fromMap(const {
        'id': 'c1',
        'workplace_id': 'wp1',
        'coefficient': 2,
        'helper_coefficient': 1.6,
        'effective_month': '2026-06-01',
      });

      expect(model.coefficient, 2);
      expect(model.helperCoefficient, 1.6);
      expect(model.effectiveHelperCoefficient, 1.6);
    });

    test('строка без ставки помощника платит по основной', () {
      final model = WorkplaceCoefficient.fromMap(const {
        'id': 'c1',
        'workplace_id': 'wp1',
        'coefficient': 2,
        'effective_month': '2026-06-01',
      });

      expect(model.helperCoefficient, isNull);
      expect(model.effectiveHelperCoefficient, 2);
    });

    test('null в колонке не превращается в ноль', () {
      // Ноль обнулил бы сдельную помощника — это совсем другое решение,
      // чем «ставка не задана».
      final model = WorkplaceCoefficient.fromMap(const {
        'id': 'c1',
        'workplace_id': 'wp1',
        'coefficient': 2,
        'helper_coefficient': null,
        'effective_month': '2026-06-01',
      });

      expect(model.helperCoefficient, isNull);
      expect(model.effectiveHelperCoefficient, 2);
    });
  });
}
