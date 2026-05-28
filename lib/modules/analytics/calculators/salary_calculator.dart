import '../models/analytics_event.dart';
import '../models/salary_adjustments.dart';
import '../models/salary_settings.dart';

/// Результат расчёта зарплаты сотрудника за месяц.
class SalaryBreakdown {
  final double pieceSalary;          // сдельная начисленная сумма
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
  final double accrued;              // начислено = piece + nightBonus
  final double deductions;           // удержания = meal + social + advance + cashless + discipline + defect
  final double total;                // итоговая ЗП

  const SalaryBreakdown({
    required this.pieceSalary,
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

  /// Полный расчёт зарплаты по сотруднику.
  static SalaryBreakdown compute({
    required List<AnalyticsEvent> events,
    required Map<String, double> coefficients,
    required SalarySettings settings,
    required SalaryAdjustments adjustments,
    required int halfShiftMinutes,
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

    final nightBonus = avgShiftSalary * nights * (settings.nightPercent / 100.0);
    final mealDeduction = shiftsTotal * settings.mealAmount;

    final compensation = adjustments.compensation;
    final social = adjustments.social;
    final advance = adjustments.advance;
    final cashless = adjustments.cashless;
    final discipline = adjustments.discipline;
    final defect = adjustments.defect;

    final accrued = pieceSalary + nightBonus + compensation;
    final deductions = mealDeduction + social + advance + cashless + discipline + defect;
    final total = accrued - deductions;

    double finite(double v) => v.isFinite ? v : 0;

    return SalaryBreakdown(
      pieceSalary: finite(pieceSalary),
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
