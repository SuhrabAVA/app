import '../models/analytics_event.dart';
import '../models/analytics_month.dart';
import '../models/employee_status_period.dart';
import '../models/pay_type.dart';
import '../models/salary_adjustments.dart';
import '../models/salary_settings.dart';

/// Строка «По статусу «Название»: N смен × ставка = сумма» в расчёте ЗП.
class StatusPayLine {
  final String statusId;
  final String statusName;
  final int shifts;
  final double rate;
  final double amount;

  const StatusPayLine({
    required this.statusId,
    required this.statusName,
    required this.shifts,
    required this.rate,
    required this.amount,
  });
}

/// Результат расчёта зарплаты сотрудника за месяц.
class SalaryBreakdown {
  final double pieceSalary;          // сдельная начисленная сумма (без дней под статусом)
  final double baseSalaryPay;        // окладная = смены (без дней под статусом) × base_day_salary
  final bool isSalaryType;           // окладник (иначе сдельщик), см. эталон
  final int shiftsTotal;
  final int dayShifts;
  final int nightShifts;
  final double averageShiftSalary;   // средняя сумма за смену (из сдельной, без дней под статусом)
  final double nightBonus;           // ночные
  final double mealDeduction;
  final double compensation;
  final double social;
  final double advance;
  final double cashless;
  final double discipline;
  final double defect;
  final double accrued;              // начислено = основная часть + ночные + компенсация + по статусу
  final double deductions;           // удержания = meal + social + advance + cashless + discipline + defect
  final double total;                // итоговая ЗП

  /// Фиксированная оплата за дни под статусом (сумма по всем статусам).
  final double fixedStatusPay;
  /// Смены, отработанные под статусом с фиксированной оплатой (подмножество shiftsTotal).
  final int statusShiftsTotal;
  /// Разбивка fixedStatusPay по статусам, для отображения построчно.
  final List<StatusPayLine> statusPayBreakdown;

  /// Оплата приладки = Σ (засчитанные приладки × цена приладки рабочего
  /// места). Входит в accrued отдельной строкой.
  final double setupPay;
  /// Количество засчитанных приладок, вошедших в setupPay.
  final double setupPayQty;

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
    this.fixedStatusPay = 0,
    this.statusShiftsTotal = 0,
    this.statusPayBreakdown = const [],
    this.setupPay = 0,
    this.setupPayQty = 0,
  });

  /// Основная (первичная) начисленная сумма по типу оплаты: окладная для
  /// окладника, сдельная для сдельщика. Именно она показывается в чипе
  /// «Сдельно/Оклад» и входит в accrued/total. Не включает fixedStatusPay —
  /// та показывается отдельной строкой/полем.
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

  /// Оплата приладки: Σ setupQty × цена приладки рабочего места.
  /// Возвращает (количество приладок с ненулевой ценой, сумма).
  static (double qty, double pay) setupPay({
    required List<AnalyticsEvent> events,
    required Map<String, double> setupPrices,
  }) {
    var qty = 0.0;
    var pay = 0.0;
    for (final e in events) {
      if (e.type != AnalyticsEventType.setup) continue;
      if (e.setupQty <= 0) continue;
      final price = setupPrices[e.workplaceId] ?? 0;
      if (price <= 0 || !price.isFinite) continue;
      final value = e.setupQty * price;
      if (!value.isFinite) continue;
      qty += e.setupQty;
      pay += value;
    }
    return (qty, pay);
  }

  /// Дата смены события: ночная смена, начавшаяся до 6 утра, относится к
  /// предыдущему календарному дню. Используется и для подсчёта смен
  /// (shiftCounts), и для определения, под каким статусом было событие —
  /// оба места должны использовать одно и то же правило, иначе границы
  /// статуса разойдутся с границами смен.
  static DateTime _shiftDateOf(DateTime start) {
    final base = DateTime(start.year, start.month, start.day);
    return start.hour < 6 ? base.subtract(const Duration(days: 1)) : base;
  }

  static String _dayKey(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

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
          e.type != AnalyticsEventType.setup) {
        continue;
      }
      final ms = e.durationMinutes();
      if (ms <= 0) continue;

      final hour = e.startTime.hour;
      final isNight = hour >= 18 || hour < 6;
      final shiftDate = _shiftDateOf(e.startTime);
      final key = '${_dayKey(shiftDate)}-${isNight ? 'n' : 'd'}';
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

  /// Карта «день месяца → statusId» для дней, покрытых статусом с
  /// НАСТРОЕННОЙ (> 0) фиксированной ставкой. Статус без ставки (или со
  /// ставкой 0) не влияет на оплату — день остаётся обычным (см. план,
  /// раздел «Unrated status»), поэтому такие дни в карту не попадают.
  static Map<String, String> _statusByDay({
    required AnalyticsMonth? month,
    required List<EmployeeStatusPeriod> periods,
    required Map<String, double> statusPayRates,
  }) {
    if (month == null || periods.isEmpty) return const {};
    final ratedPeriods =
        periods.where((p) => (statusPayRates[p.statusId] ?? 0) > 0).toList();
    if (ratedPeriods.isEmpty) return const {};

    final result = <String, String>{};
    for (var i = 0; i < month.daysCount; i++) {
      final day = month.firstDay.add(Duration(days: i));
      for (final p in ratedPeriods) {
        if (p.covers(day)) {
          result[_dayKey(day)] = p.statusId;
          break; // Периоды не должны перекрываться (гарантируется БД).
        }
      }
    }
    return result;
  }

  /// Полный расчёт зарплаты по сотруднику.
  ///
  /// Дни, покрытые активным статусом с фиксированной ставкой, полностью
  /// исключаются из сдельного/окладного расчёта (события этих дней не
  /// попадают ни в pieceSalary, ни в смены для baseSalaryPay) и вместо этого
  /// оплачиваются по ставке статуса × отработанные смены под статусом.
  /// Ночные/питание считаются по ВСЕМ сменам (не подавляются статусом) —
  /// это не «сдельная оплата». Если [statusPeriods] пуст — расчёт полностью
  /// эквивалентен предыдущей версии (обратная совместимость).
  static SalaryBreakdown compute({
    required List<AnalyticsEvent> events,
    required Map<String, double> coefficients,
    required SalarySettings settings,
    required SalaryAdjustments adjustments,
    required int halfShiftMinutes,
    double baseDaySalary = 0,
    PayType? payType,
    AnalyticsMonth? month,
    List<EmployeeStatusPeriod> statusPeriods = const [],
    Map<String, double> statusPayRates = const {},
    Map<String, String> statusNames = const {},
    Map<String, double> setupPrices = const {},
  }) {
    final statusByDay = _statusByDay(
      month: month,
      periods: statusPeriods,
      statusPayRates: statusPayRates,
    );

    // Разносим ВСЕ события (work/setup/pause/problem и т.д.) по обычным
    // дням и дням под статусом — shiftCounts должен видеть полный набор
    // событий дня (приладка тоже учитывается в минутах смены).
    final List<AnalyticsEvent> normalEvents;
    final Map<String, List<AnalyticsEvent>> eventsByStatus;
    if (statusByDay.isEmpty) {
      normalEvents = events;
      eventsByStatus = const {};
    } else {
      final normal = <AnalyticsEvent>[];
      final byStatus = <String, List<AnalyticsEvent>>{};
      for (final e in events) {
        final statusId = statusByDay[_dayKey(_shiftDateOf(e.startTime))];
        if (statusId == null) {
          normal.add(e);
        } else {
          byStatus.putIfAbsent(statusId, () => []).add(e);
        }
      }
      normalEvents = normal;
      eventsByStatus = byStatus;
    }

    // ── Обычная часть (дни без статуса) — формулы как раньше ──────────────
    final pieceSalary =
        piecewise(workEvents: normalEvents, workplaceCoefficients: coefficients);
    // Оплата приладки — сдельного типа, поэтому, как и pieceSalary, считается
    // только по обычным дням (дни под статусом оплачиваются ставкой статуса).
    final (setupQtyPaid, setupPayAmount) =
        setupPay(events: normalEvents, setupPrices: setupPrices);
    final (normalDays, normalNights) =
        shiftCounts(events: normalEvents, halfShiftMinutes: halfShiftMinutes);
    final normalShiftsTotal = normalDays + normalNights;

    final baseSalaryPay = normalShiftsTotal * baseDaySalary;
    final salaryType =
        isSalaryType(payType: payType, pieceSalary: pieceSalary);
    final primaryEarned = salaryType ? baseSalaryPay : pieceSalary;

    // ── Часть по статусам ───────────────────────────────────────────────
    var statusDaysSum = 0;
    var statusNightsSum = 0;
    var fixedStatusPay = 0.0;
    final statusLines = <StatusPayLine>[];
    final statusIds = eventsByStatus.keys.toList()
      ..sort((a, b) => (statusNames[a] ?? a).compareTo(statusNames[b] ?? b));
    for (final sId in statusIds) {
      final (sDays, sNights) = shiftCounts(
          events: eventsByStatus[sId]!, halfShiftMinutes: halfShiftMinutes);
      final sShifts = sDays + sNights;
      final rate = statusPayRates[sId] ?? 0;
      final amount = sShifts * rate;
      statusDaysSum += sDays;
      statusNightsSum += sNights;
      fixedStatusPay += amount;
      statusLines.add(StatusPayLine(
        statusId: sId,
        statusName: statusNames[sId] ?? sId,
        shifts: sShifts,
        rate: rate,
        amount: amount,
      ));
    }
    final statusShiftsTotal = statusDaysSum + statusNightsSum;

    // ── Итоговые смены (обычные + под статусом) ────────────────────────
    final dayShifts = normalDays + statusDaysSum;
    final nightShifts = normalNights + statusNightsSum;
    final shiftsTotal = dayShifts + nightShifts;

    // avgShiftSalary специально делится на normalShiftsTotal (не на
    // shiftsTotal): иначе месяцы с преобладанием статусных смен занижали бы
    // среднюю сдельную и, следом, ночную надбавку.
    final avgShiftSalary =
        normalShiftsTotal > 0 ? pieceSalary / normalShiftsTotal : 0.0;
    final nightBonus = avgShiftSalary * nightShifts * (settings.nightPercent / 100.0);
    final mealDeduction = shiftsTotal * settings.mealAmount;

    final compensation = adjustments.compensation;
    final social = adjustments.social;
    final advance = adjustments.advance;
    final cashless = adjustments.cashless;
    final discipline = adjustments.discipline;
    final defect = adjustments.defect;

    final accrued =
        primaryEarned + nightBonus + compensation + fixedStatusPay + setupPayAmount;
    // Питание оплачивает компания, поэтому из зарплаты сотрудника оно НЕ
    // удерживается. Значение mealDeduction остаётся в разбивке — таблицы и
    // PDF показывают его как расход компании (смены × цена порции), но в
    // сумму удержаний и в итог ЗП оно не входит.
    final deductions = social + advance + cashless + discipline + defect;
    final total = accrued - deductions;

    double finite(double v) => v.isFinite ? v : 0;

    return SalaryBreakdown(
      pieceSalary: finite(pieceSalary),
      baseSalaryPay: finite(baseSalaryPay),
      isSalaryType: salaryType,
      shiftsTotal: shiftsTotal,
      dayShifts: dayShifts,
      nightShifts: nightShifts,
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
      fixedStatusPay: finite(fixedStatusPay),
      statusShiftsTotal: statusShiftsTotal,
      statusPayBreakdown: statusLines,
      setupPay: finite(setupPayAmount),
      setupPayQty: finite(setupQtyPaid),
    );
  }
}

class _DayBuckets {
  int dayMinutes = 0;
  int nightMinutes = 0;
}
