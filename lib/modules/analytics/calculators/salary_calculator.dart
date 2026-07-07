import '../models/analytics_event.dart';
import '../models/pay_type.dart';
import '../models/salary_adjustments.dart';
import '../models/salary_settings.dart';

/// Результат расчёта зарплаты сотрудника за месяц.
class SalaryBreakdown {
  final double pieceSalary;          // сдельная начисленная сумма
  final double baseSalaryPay;        // окладная = смены × base_day_salary
  final bool isSalaryType;           // окладник (иначе сдельщик), см. эталон
  final int shiftsTotal;
  final int dayShifts;
  final int nightShifts;
  final double averageShiftSalary;   // средняя сумма за смену (из сдельной)
  final double nightBonus;           // ночные
  final double mealDeduction;
  final double compensation;
  final double social;
  final double advance;
  final double cashless;
  final double discipline;
  final double defect;
  final double accrued;              // начислено = основная часть + ночные + компенсация
  final double deductions;           // удержания = meal + social + advance + cashless + discipline + defect
  final double total;                // итоговая ЗП

  const SalaryBreakdown({
    required this.pieceSalary,
    required this.baseSalaryPay,
    required this.isSalaryType,
    required this.shiftsTotal,
    required this.dayShifts,
    required this.nightShifts,
    required this.averageShiftSalary,
    required this.nightBonus,
    required this.mealDeduction,
    required this.compensation,
    required this.social,
    required this.advance,
    required this.cashless,
    required this.discipline,
    required this.defect,
    required this.accrued,
    required this.deductions,
    required this.total,
  });

  /// Основная (первичная) начисленная сумма по типу оплаты: окладная для
  /// окладника, сдельная для сдельщика. Именно она показывается в чипе
  /// «Сдельно/Оклад» и входит в accrued/total.
  double get primaryEarned => isSalaryType ? baseSalaryPay : pieceSalary;
}

class SalaryCalculator {
  SalaryCalculator._();

  /// Рассчитывает сдельную часть зарплаты.
  static double piecewise({
    required List<AnalyticsEvent> workEvents,
    required Map<String, double> workplaceCoefficients,
  }) {
    var sum = 0.0;
    for (final e in workEvents) {
      if (e.type != AnalyticsEventType.work) continue;
      final coeff = workplaceCoefficients[e.workplaceId] ?? 0;
      if (!coeff.isFinite) continue;
      final value = e.qty * coeff;
      if (value.isFinite) sum += value;
    }
    return sum;
  }

  /// Подсчёт смен. Смена засчитывается, если работа за день >= halfShift.
  /// Возвращает (days, nights).
  static (int days, int nights) shiftCounts({
    required Iterable<AnalyticsEvent> events,
    required int halfShiftMinutes,
  }) {
    // Сгруппировать минуты работы по (дата, тип смены).
    final byDay = <String, _DayBuckets>{};
    for (final e in events) {
      if (e.type != AnalyticsEventType.work &&
          e.type != AnalyticsEventType.setup) continue;
      final ms = e.durationMinutes();
      if (ms <= 0) continue;

      // Определяем тип смены: <6 — относится к предыдущему дню (ночная),
      // 6..17 — дневная, >=18 — ночная этого дня.
      final hour = e.startTime.hour;
      final isNight = hour >= 18 || hour < 6;
      final shiftDate = (hour < 6)
          ? e.startTime.subtract(const Duration(days: 1))
          : e.startTime;
      final key =
          '${shiftDate.year}-${shiftDate.month.toString().padLeft(2, '0')}-${shiftDate.day.toString().padLeft(2, '0')}-${isNight ? 'n' : 'd'}';
      final bucket = byDay.putIfAbsent(key, () => _DayBuckets());
      if (isNight) {
        bucket.nightMinutes += ms;
      } else {
        bucket.dayMinutes += ms;
      }
    }

    var days = 0;
    var nights = 0;
    byDay.forEach((key, bucket) {
      if (bucket.dayMinutes >= halfShiftMinutes) days++;
      if (bucket.nightMinutes >= halfShiftMinutes) nights++;
    });
    return (days, nights);
  }

  /// Определяет, окладник ли сотрудник (иначе сдельщик), по логике эталона
  /// (app.js payTypeLabel):
  ///   isSalary = payType == salary || (productionPay <= 0 && payType != piece)
  static bool isSalaryType({
    required PayType? payType,
    required double pieceSalary,
  }) {
    if (payType == PayType.salary) return true;
    if (payType == PayType.piece) return false;
    // mixed или не задан — по факту: нет сдельной выработки → оклад.
    return pieceSalary <= 0;
  }

  /// Полный расчёт зарплаты по сотруднику.
  ///
  /// Окладная часть = смены × [baseDaySalary]. В accrued/total входит ОСНОВНАЯ
  /// часть по типу оплаты ([payType]): окладная для окладника, сдельная для
  /// сдельщика (см. [isSalaryType]). Ночные и питание считаются как в эталоне.
  static SalaryBreakdown compute({
    required List<AnalyticsEvent> events,
    required Map<String, double> coefficients,
    required SalarySettings settings,
    required SalaryAdjustments adjustments,
    required int halfShiftMinutes,
    double baseDaySalary = 0,
    PayType? payType,
  }) {
    final workEvents =
        events.where((e) => e.type == AnalyticsEventType.work).toList();

    final pieceSalary =
        piecewise(workEvents: workEvents, workplaceCoefficients: coefficients);
    final (days, nights) =
        shiftCounts(events: events, halfShiftMinutes: halfShiftMinutes);
    final shiftsTotal = days + nights;
    final avgShiftSalary =
        shiftsTotal > 0 ? pieceSalary / shiftsTotal : 0.0;

    final baseSalaryPay = shiftsTotal * baseDaySalary;
    final salaryType =
        isSalaryType(payType: payType, pieceSalary: pieceSalary);
    final primaryEarned = salaryType ? baseSalaryPay : pieceSalary;

    final nightBonus = avgShiftSalary * nights * (settings.nightPercent / 100.0);
    final mealDeduction = shiftsTotal * settings.mealAmount;

    final compensation = adjustments.compensation;
    final social = adjustments.social;
    final advance = adjustments.advance;
    final cashless = adjustments.cashless;
    final discipline = adjustments.discipline;
    final defect = adjustments.defect;

    final accrued = primaryEarned + nightBonus + compensation;
    final deductions = mealDeduction + social + advance + cashless + discipline + defect;
    final total = accrued - deductions;

    double finite(double v) => v.isFinite ? v : 0;

    return SalaryBreakdown(
      pieceSalary: finite(pieceSalary),
      baseSalaryPay: finite(baseSalaryPay),
      isSalaryType: salaryType,
      shiftsTotal: shiftsTotal,
      dayShifts: days,
      nightShifts: nights,
      averageShiftSalary: finite(avgShiftSalary),
      nightBonus: finite(nightBonus),
      mealDeduction: finite(mealDeduction),
      compensation: finite(compensation),
      social: finite(social),
      advance: finite(advance),
      cashless: finite(cashless),
      discipline: finite(discipline),
      defect: finite(defect),
      accrued: finite(accrued),
      deductions: finite(deductions),
      total: finite(total),
    );
  }
}

class _DayBuckets {
  int dayMinutes = 0;
  int nightMinutes = 0;
}
