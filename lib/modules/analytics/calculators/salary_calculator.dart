import '../../../utils/shift_day.dart';
import '../models/analytics_event.dart';
import '../models/analytics_month.dart';
import '../models/day_shift_type.dart';
import '../models/employee_status_period.dart';
import '../models/pay_type.dart';
import '../models/salary_adjustments.dart';
import '../models/salary_settings.dart';
import '../models/workplace_coefficient.dart' show helperCoefficientOrMain;

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
  ///
  /// [helperCoefficients] — собственная ставка помощника совместной работы
  /// (workplaceId -> ₸ за единицу). Ответственность и объём работы у
  /// основного исполнителя больше, поэтому за ту же выработку помощнику
  /// платят по своей цене. Рабочее место без записи — ставка основного, то
  /// есть оплата поровну.
  ///
  /// Количество в событиях уже персональное: на обычных рабочих местах это
  /// доля по отработанному времени, на станках (split_quantity_by_time =
  /// false) — полный тираж каждому. Умножать здесь ещё на какой-либо
  /// множитель нельзя: вклад уже учтён в количестве.
  static double piecewise({
    required List<AnalyticsEvent> workEvents,
    required Map<String, double> workplaceCoefficients,
    Map<String, double> helperCoefficients = const {},
  }) {
    var sum = 0.0;
    for (final e in workEvents) {
      if (e.type != AnalyticsEventType.work) continue;
      final main = workplaceCoefficients[e.workplaceId] ?? 0;
      if (!main.isFinite) continue;
      final rate = e.isHelper
          ? helperCoefficientOrMain(helperCoefficients[e.workplaceId], main)
          : main;
      if (!rate.isFinite) continue;
      final value = e.qty * rate;
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

  /// Дата смены события — общее правило, см. [shiftDayOf]. Тем же правилом
  /// закрываются периоды статуса (employee_status_repository), иначе день на
  /// стыке был бы оплачен по одному правилу, а посчитан по другому.
  static DateTime _shiftDateOf(DateTime start) => shiftDayOf(start);

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

  /// День месяца под статусом с настроенной ставкой.
  static _StatusDay? _statusDayOf({
    required DateTime day,
    required List<EmployeeStatusPeriod> ratedPeriods,
  }) {
    for (final p in ratedPeriods) {
      if (p.covers(day)) {
        // Периоды не должны перекрываться (гарантируется БД).
        return _StatusDay(statusId: p.statusId, dayOfMonth: day.day);
      }
    }
    return null;
  }

  /// Карта «ключ дня → статус» для дней, покрытых статусом с НАСТРОЕННОЙ
  /// (> 0) фиксированной ставкой. Статус без ставки (или со ставкой 0) не
  /// влияет на оплату — день остаётся обычным (см. план, раздел «Unrated
  /// status»), поэтому такие дни в карту не попадают.
  static Map<String, _StatusDay> _statusByDay({
    required AnalyticsMonth? month,
    required List<EmployeeStatusPeriod> periods,
    required Map<String, double> statusPayRates,
  }) {
    if (month == null || periods.isEmpty) return const {};
    final ratedPeriods =
        periods.where((p) => (statusPayRates[p.statusId] ?? 0) > 0).toList();
    if (ratedPeriods.isEmpty) return const {};

    final result = <String, _StatusDay>{};
    for (var i = 0; i < month.daysCount; i++) {
      final day = month.firstDay.add(Duration(days: i));
      final statusDay = _statusDayOf(day: day, ratedPeriods: ratedPeriods);
      if (statusDay != null) result[_dayKey(day)] = statusDay;
    }
    return result;
  }

  /// Смены под статусом [statusId].
  ///
  /// Приоритет у графика: если день назначен сменой (день/ночь), он
  /// засчитывается целиком, сколько бы сотрудник ни отработал и отметился ли
  /// вообще. Оплата по статусу — фиксированная за смену, а не за часы, и
  /// уборщик с охранником заданий не выполняют: по событиям им нечего было бы
  /// засчитать. Если графика на день нет (или там выходной, а человек
  /// работал), считаем по событиям — прежнее правило «отработал ≥ полсмены».
  static (int days, int nights) _statusShiftCounts({
    required String statusId,
    required Map<String, _StatusDay> statusByDay,
    required List<AnalyticsEvent> statusEvents,
    required Map<int, DayShiftType> scheduledShifts,
    required int halfShiftMinutes,
  }) {
    final eventsByDayKey = <String, List<AnalyticsEvent>>{};
    for (final e in statusEvents) {
      eventsByDayKey
          .putIfAbsent(_dayKey(_shiftDateOf(e.startTime)), () => [])
          .add(e);
    }

    var days = 0;
    var nights = 0;
    for (final entry in statusByDay.entries) {
      final statusDay = entry.value;
      if (statusDay.statusId != statusId) continue;

      switch (scheduledShifts[statusDay.dayOfMonth]) {
        case DayShiftType.day:
          days++;
          continue;
        case DayShiftType.night:
          nights++;
          continue;
        case DayShiftType.off:
        case null:
          break;
      }

      final (d, n) = shiftCounts(
        events: eventsByDayKey[entry.key] ?? const [],
        halfShiftMinutes: halfShiftMinutes,
      );
      days += d;
      nights += n;
    }
    return (days, nights);
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
    Map<int, DayShiftType> scheduledShifts = const {},
    Map<String, double> helperCoefficients = const {},
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
        final statusDay = statusByDay[_dayKey(_shiftDateOf(e.startTime))];
        if (statusDay == null) {
          normal.add(e);
        } else {
          byStatus.putIfAbsent(statusDay.statusId, () => []).add(e);
        }
      }
      normalEvents = normal;
      eventsByStatus = byStatus;
    }

    // ── Обычная часть (дни без статуса) — формулы как раньше ──────────────
    final pieceSalary = piecewise(
      workEvents: normalEvents,
      workplaceCoefficients: coefficients,
      helperCoefficients: helperCoefficients,
    );
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
    // Список статусов берётся из ДНЕЙ, а не из событий: уборщик или охранник
    // не выполняют заданий вообще, и по событиям их статус был бы не найден,
    // а смена — не оплачена.
    final statusIds = <String>{
      ...statusByDay.values.map((d) => d.statusId),
      ...eventsByStatus.keys,
    }.toList()
      ..sort((a, b) => (statusNames[a] ?? a).compareTo(statusNames[b] ?? b));
    for (final sId in statusIds) {
      final (sDays, sNights) = _statusShiftCounts(
        statusId: sId,
        statusByDay: statusByDay,
        statusEvents: eventsByStatus[sId] ?? const [],
        scheduledShifts: scheduledShifts,
        halfShiftMinutes: halfShiftMinutes,
      );
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

/// День месяца, покрытый статусом с настроенной ставкой.
class _StatusDay {
  const _StatusDay({required this.statusId, required this.dayOfMonth});

  final String statusId;
  final int dayOfMonth;
}
