import 'package:flutter/foundation.dart';

import '../../orders/orders_provider.dart';
import '../../personnel/employee_attendance_repository.dart';
import '../../personnel/employee_status_model.dart';
import '../../personnel/employee_status_repository.dart';
import '../../personnel/personnel_provider.dart';
import '../../tasks/task_provider.dart';
import '../models/analytics_day_comment.dart';
import '../models/analytics_event.dart';
import '../models/analytics_month.dart';
import '../models/claim_model.dart';
import '../models/day_shift_type.dart';
import '../models/employee_status_period.dart';
import '../models/salary_adjustments.dart';
import '../models/salary_settings.dart';
import '../models/work_schedule_entry.dart';
import '../repositories/analytics_repository.dart';
import '../repositories/claims_repository.dart';
import '../repositories/employee_pay_settings_repository.dart';
import '../repositories/employee_status_pay_rate_repository.dart';
import '../repositories/prod_stage_history_repository.dart';
import '../repositories/salary_adjustments_repository.dart';
import '../repositories/salary_settings_repository.dart';
import '../repositories/work_schedule_repository.dart';
import '../models/workplace_coefficient.dart';
import '../repositories/workplace_coefficient_repository.dart';
import 'analytics_permission_service.dart';

/// Состояние данных аналитики на выбранный месяц.
class AnalyticsState {
  final AnalyticsMonth month;
  final List<AnalyticsEvent> events;
  /// Отображаемые события/комментарии этапов для лент дня. Аддитивный слой:
  /// не участвует в расчётах зарплаты/КПД.
  final List<AnalyticsDayComment> dayComments;
  final Map<String, double> coefficients;

  /// Ставки помощников совместной работы: workplaceId -> ₸ за единицу.
  /// Рабочее место без записи оплачивает помощника по ставке основного
  /// исполнителя. Финансовые данные.
  final Map<String, double> helperCoefficients;
  final SalarySettings settings;
  final Map<String, SalaryAdjustments> adjustments;
  final Map<String, Map<int, WorkScheduleEntry>> schedules;
  final List<EmployeeStatus> statuses;
  final Map<String, String> employeeStatusIds;
  /// Периоды действия статусов по сотрудникам, пересекающие выбранный
  /// месяц (для расчёта ЗП по дням под статусом). Не финансовые данные —
  /// грузятся всегда, в т.ч. в selfView.
  final Map<String, List<EmployeeStatusPeriod>> employeeStatusHistory;
  /// Фиксированные ставки за смену по статусам (statusId -> ₸/смена).
  /// Финансовые данные — грузятся только при canViewFinance.
  final Map<String, double> statusPayRates;
  final Map<String, String?> employeePayTypes;
  /// Оклад за смену по сотруднику (base_day_salary). Авторитетный источник
  /// окладной части ЗП — грузится из таблицы employees (view её не отдаёт).
  final Map<String, double> employeeBaseSalaries;
  final List<ClaimModel> claims;

  /// Отметки прихода/ухода: employeeId → день месяца → отметка. Только для
  /// показа — начисление идёт по графику, отметка на него не влияет.
  final Map<String, Map<int, EmployeeAttendanceDay>> attendance;

  /// Помесячные скорости рабочих мест за все месяцы до выбранного.
  /// Используется для расчёта КПД.
  final Map<String, List<double>> workplacePreviousSpeeds;

  /// Тираж по рабочим местам за месяц: workplaceId -> сумма записей
  /// «сделано на этапе». Это выработка САМОГО рабочего места, а не сумма
  /// выработки людей: на станках каждому участнику записан полный тираж.
  final Map<String, double> workplaceStageTotals;
  final bool loading;
  final Object? error;

  AnalyticsState({
    required this.month,
    this.events = const [],
    this.dayComments = const [],
    this.coefficients = const {},
    this.helperCoefficients = const {},
    SalarySettings? settings,
    this.adjustments = const {},
    this.schedules = const {},
    this.statuses = const [],
    this.employeeStatusIds = const {},
    this.employeeStatusHistory = const {},
    this.statusPayRates = const {},
    this.employeePayTypes = const {},
    this.employeeBaseSalaries = const {},
    this.claims = const [],
    this.attendance = const {},
    this.workplacePreviousSpeeds = const {},
    this.workplaceStageTotals = const {},
    this.loading = false,
    this.error,
  }) : settings = settings ?? SalarySettings.defaults(month.firstDay);

  /// График сотрудника на месяц: день месяца → тип смены. Расчёт ЗП берёт
  /// отсюда смены под статусом (уборщик/охранник заданий не выполняют, по
  /// событиям им нечего засчитать).
  Map<int, DayShiftType> scheduledShiftsFor(String employeeId) {
    final byDay = schedules[employeeId];
    if (byDay == null || byDay.isEmpty) return const {};
    return {
      for (final entry in byDay.entries) entry.key: entry.value.shiftType,
    };
  }

  AnalyticsState copyWith({
    AnalyticsMonth? month,
    List<AnalyticsEvent>? events,
    List<AnalyticsDayComment>? dayComments,
    Map<String, double>? coefficients,
    Map<String, double>? helperCoefficients,
    SalarySettings? settings,
    Map<String, SalaryAdjustments>? adjustments,
    Map<String, Map<int, WorkScheduleEntry>>? schedules,
    List<EmployeeStatus>? statuses,
    Map<String, String>? employeeStatusIds,
    Map<String, List<EmployeeStatusPeriod>>? employeeStatusHistory,
    Map<String, double>? statusPayRates,
    Map<String, String?>? employeePayTypes,
    Map<String, double>? employeeBaseSalaries,
    List<ClaimModel>? claims,
    Map<String, Map<int, EmployeeAttendanceDay>>? attendance,
    Map<String, List<double>>? workplacePreviousSpeeds,
    Map<String, double>? workplaceStageTotals,
    bool? loading,
    Object? error,
    bool clearError = false,
  }) {
    return AnalyticsState(
      month: month ?? this.month,
      events: events ?? this.events,
      dayComments: dayComments ?? this.dayComments,
      coefficients: coefficients ?? this.coefficients,
      helperCoefficients: helperCoefficients ?? this.helperCoefficients,
      settings: settings ?? this.settings,
      adjustments: adjustments ?? this.adjustments,
      schedules: schedules ?? this.schedules,
      statuses: statuses ?? this.statuses,
      employeeStatusIds: employeeStatusIds ?? this.employeeStatusIds,
      employeeStatusHistory: employeeStatusHistory ?? this.employeeStatusHistory,
      statusPayRates: statusPayRates ?? this.statusPayRates,
      employeePayTypes: employeePayTypes ?? this.employeePayTypes,
      employeeBaseSalaries: employeeBaseSalaries ?? this.employeeBaseSalaries,
      claims: claims ?? this.claims,
      attendance: attendance ?? this.attendance,
      workplacePreviousSpeeds:
          workplacePreviousSpeeds ?? this.workplacePreviousSpeeds,
      workplaceStageTotals: workplaceStageTotals ?? this.workplaceStageTotals,
      loading: loading ?? this.loading,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

/// Центральный сервис аналитики.
///
/// Опирается на существующие провайдеры (PersonnelProvider/OrdersProvider/
/// TaskProvider) и репозитории нового модуля. Самостоятельно не подписывается
/// на realtime — экран сам пересчитывает данные, когда провайдеры notifyListeners.
class AnalyticsService extends ChangeNotifier {
  AnalyticsService({
    required this.personnel,
    required this.orders,
    required this.tasks,
    WorkplaceCoefficientRepository? coefficientsRepo,
    SalarySettingsRepository? salarySettingsRepo,
    SalaryAdjustmentsRepository? adjustmentsRepo,
    WorkScheduleRepository? scheduleRepo,
    EmployeeStatusRepository? statusRepo,
    EmployeePaySettingsRepository? payRepo,
    EmployeeStatusPayRateRepository? statusRateRepo,
    ClaimsRepository? claimsRepo,
    EmployeeAttendanceRepository? attendanceRepo,
    AnalyticsRepository? analyticsRepo,
    ProdStageHistoryRepository? historyRepo,
    AnalyticsPermissionService? permission,
  })  : _coefficientsRepo = coefficientsRepo ?? WorkplaceCoefficientRepository(),
        _salarySettingsRepo = salarySettingsRepo ?? SalarySettingsRepository(),
        _adjustmentsRepo = adjustmentsRepo ?? SalaryAdjustmentsRepository(),
        _scheduleRepo = scheduleRepo ?? WorkScheduleRepository(),
        // Статусы — read-only здесь: репозиторий модуля персонала (владелец
        // записи/истории). Аналитика только читает для отображения/расчёта.
        _statusRepo = statusRepo ?? EmployeeStatusRepository(),
        _payRepo = payRepo ?? EmployeePaySettingsRepository(),
        _statusRateRepo = statusRateRepo ?? EmployeeStatusPayRateRepository(),
        _claimsRepo = claimsRepo ?? ClaimsRepository(),
        _attendanceRepo = attendanceRepo ?? EmployeeAttendanceRepository(),
        _analyticsRepo = analyticsRepo ?? AnalyticsRepository(),
        _historyRepo = historyRepo ?? ProdStageHistoryRepository(),
        _permission = permission;

  final PersonnelProvider personnel;
  final OrdersProvider orders;
  final TaskProvider tasks;

  final WorkplaceCoefficientRepository _coefficientsRepo;
  final SalarySettingsRepository _salarySettingsRepo;
  final SalaryAdjustmentsRepository _adjustmentsRepo;
  final WorkScheduleRepository _scheduleRepo;
  final EmployeeStatusRepository _statusRepo;
  final EmployeePaySettingsRepository _payRepo;
  final EmployeeStatusPayRateRepository _statusRateRepo;
  final ClaimsRepository _claimsRepo;
  final EmployeeAttendanceRepository _attendanceRepo;
  final AnalyticsRepository _analyticsRepo;
  final ProdStageHistoryRepository _historyRepo;
  final AnalyticsPermissionService? _permission;

  AnalyticsState _state =
      AnalyticsState(month: AnalyticsMonth.current(), loading: true);
  AnalyticsState get state => _state;

  bool _loadInProgress = false;
  bool _hasLoadedOnce = false;
  AnalyticsMonth? _queuedMonth;

  // Фоновый _loadMonthOnce может резолвиться уже после того, как экран
  // закрыли и вызвал dispose() (Timer.cancel() не отменяет уже идущий
  // await-чейн) — тогда notifyListeners() падает с "used after disposed".
  // Флаг превращает это в безопасный no-op вместо падения/шумного лога.
  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  Future<void> loadMonth(AnalyticsMonth month) async {
    // Провайдеры (tasks/orders) уведомляют при каждом realtime-событии;
    // без guard'а параллельные loadMonth гоняли таблицу через
    // loading→data каждую секунду (пересоздание таблицы + спам overflow).
    if (_loadInProgress) {
      _queuedMonth = month;
      return;
    }
    _loadInProgress = true;
    try {
      var current = month;
      while (true) {
        await _loadMonthOnce(current);
        final queued = _queuedMonth;
        _queuedMonth = null;
        if (queued == null) break;
        current = queued;
      }
    } finally {
      _loadInProgress = false;
    }
  }

  Future<void> _loadMonthOnce(AnalyticsMonth month) async {
    // Фоновое обновление того же месяца выполняем «тихо»: старые данные
    // остаются на экране, таблица не заменяется на экран загрузки.
    final silent =
        _hasLoadedOnce && month == _state.month && _state.error == null;
    if (!silent) {
      _state = _state.copyWith(month: month, loading: true, clearError: true);
      notifyListeners();
    }
    try {
      // Fire all requests in parallel: one DB scan covers both events and
      // previous speeds; the rest are independent lightweight queries.
      // Финансовые запросы (salary_*, коэффициенты, оклады, тип оплаты)
      // выполняем только при праве на финансы: в selfView сотрудника эти
      // данные не должны даже попадать на клиент (deny-by-default).
      final loadFinance = _permission?.canViewFinance == true;
      final allDataFuture = _analyticsRepo.loadAllMonthData(month);
      final coeffsFuture = loadFinance
          ? _coefficientsRepo.loadEffective(month.firstDay)
          : Future.value(const <String, double>{});
      final helperCoefficientsFuture = loadFinance
          ? _coefficientsRepo.loadEffectiveHelperCoefficients(month.firstDay)
          : Future.value(const <String, double>{});
      final settingsFuture = loadFinance
          ? _salarySettingsRepo.loadEffective(month.firstDay)
          : Future.value(SalarySettings.defaults(month.firstDay));
      final adjustmentsFuture = loadFinance
          ? _adjustmentsRepo.loadForMonth(month.firstDay)
          : Future.value(const <String, SalaryAdjustments>{});
      final schedulesFuture = _scheduleRepo.loadForMonth(month.firstDay);
      // Статусы (справочник/текущий/история) — не финансовые данные, нужны
      // и в selfView (badge, история для расчёта "своих" смен под статусом).
      final statusesFuture = _statusRepo.listAll();
      final employeeStatusIdsFuture = _statusRepo.loadCurrentStatusIds();
      final statusHistoryFuture = _statusRepo.loadHistoryForMonth(month.firstDay);
      final employeePayTypesFuture = loadFinance
          ? _payRepo.loadEmployeePayTypes()
          : Future.value(const <String, String?>{});
      final employeeBaseSalariesFuture = loadFinance
          ? _payRepo.loadEmployeeBaseSalaries()
          : Future.value(const <String, double>{});
      // Ставки статусов — финансовые данные, гейтятся как коэффициенты.
      final statusRatesFuture = loadFinance
          ? _statusRateRepo.loadEffective(month.firstDay)
          : Future.value(const <String, double>{});
      final claimsFuture = _claimsRepo.listForMonth(month.firstDay);
      // Отметки прихода/ухода — только для показа: на начисление не влияют
      // (смена под статусом оплачивается по графику). Таблица появилась
      // отдельной миграцией, поэтому её отсутствие не должно валить месяц.
      final attendanceFuture = _attendanceRepo
          .loadForMonth(month.firstDay)
          .catchError((_) => <String, Map<int, EmployeeAttendanceDay>>{});

      final allData = await allDataFuture;
      final coeffs = await coeffsFuture;
      final settings = await settingsFuture;
      final adjustments = await adjustmentsFuture;
      final schedules = await schedulesFuture;
      final statuses = await statusesFuture;
      final empStatusIds = await employeeStatusIdsFuture;
      final statusHistoryRows = await statusHistoryFuture;
      final empPayTypes = await employeePayTypesFuture;
      final empBaseSalaries = await employeeBaseSalariesFuture;
      final statusRates = await statusRatesFuture;
      final claims = await claimsFuture;

      final employeeStatusHistory = <String, List<EmployeeStatusPeriod>>{
        for (final entry in statusHistoryRows.entries)
          entry.key: entry.value
              .map((row) => EmployeeStatusPeriod(
                    statusId: row.statusId,
                    dateFrom: row.dateFrom,
                    dateTo: row.dateTo,
                  ))
              .toList(),
      };

      // If the task-comment tracker produced no events for this month,
      // fall back to prod_stage_history transitions (fills historical months).
      List<AnalyticsEvent> events = allData.events;
      if (events.isEmpty) {
        try {
          final historyEvents = await _historyRepo.loadEventsForMonth(
            month,
            personnel.workplaces,
          );
          if (historyEvents.isNotEmpty) events = historyEvents;
        } catch (_) {
          // Stage history is optional; ignore errors.
        }
      }

      _state = AnalyticsState(
        month: month,
        events: events,
        dayComments: allData.dayComments,
        coefficients: coeffs,
        helperCoefficients: await helperCoefficientsFuture,
        settings: settings,
        adjustments: adjustments,
        schedules: schedules,
        statuses: statuses,
        employeeStatusIds: empStatusIds,
        employeeStatusHistory: employeeStatusHistory,
        statusPayRates: statusRates,
        employeePayTypes: empPayTypes,
        employeeBaseSalaries: empBaseSalaries,
        claims: claims,
        attendance: await attendanceFuture,
        workplacePreviousSpeeds: allData.prevSpeeds,
        workplaceStageTotals: allData.workplaceStageTotals,
        loading: false,
      );
      _hasLoadedOnce = true;
      if (_disposed) return;
      notifyListeners();
    } catch (e) {
      // При тихом фоновом обновлении не подменяем живую таблицу экраном
      // ошибки — оставляем прежние данные.
      if (silent) {
        debugPrint('⚠️ Analytics background refresh failed: $e');
        return;
      }
      _state = _state.copyWith(loading: false, error: e);
      if (_disposed) return;
      notifyListeners();
    }
  }

  Future<void> refresh() => loadMonth(_state.month);

  /// Цены за приладку по рабочим местам с включённой приладкой
  /// (workplaces.priladka_price). Финансовые данные — вне canViewFinance
  /// возвращается пустая карта (setupPay в расчёте будет 0).
  Map<String, double> get workplaceSetupPrices {
    if (_permission?.canViewFinance != true) return const {};
    return {
      for (final w in personnel.workplaces)
        if (w.hasMachine) w.id: w.priladkaPrice,
    };
  }

  /// Сохраняет цену за одну приладку рабочего места (workplaces.priladka_price).
  Future<void> setWorkplaceSetupPrice({
    required String workplaceId,
    required double price,
  }) async {
    if (_permission?.canEdit != true) {
      throw StateError('У вас нет прав на изменение финансовых данных.');
    }
    await personnel.setWorkplacePriladkaPrice(id: workplaceId, price: price);
    notifyListeners();
  }

  /// Сохраняет коэффициент рабочего места на текущий месяц.
  Future<void> setWorkplaceCoefficient({
    required String workplaceId,
    required double coefficient,
    String? actorId,
  }) async {
    if (_permission?.canEdit != true) {
      throw StateError('У вас нет прав на изменение финансовых данных.');
    }
    await _coefficientsRepo.upsert(
      permission: _permission,
      workplaceId: workplaceId,
      coefficient: coefficient,
      month: _state.month.firstDay,
      updatedBy: actorId,
    );
    final next = Map<String, double>.from(_state.coefficients);
    next[workplaceId] = coefficient;
    _state = _state.copyWith(coefficients: next);
    notifyListeners();
  }

  /// Ставка помощника совместной работы, ₸ за единицу.
  ///
  /// null (или пустое поле в форме) — платить помощнику по ставке основного
  /// исполнителя.
  ///
  /// Коэффициент рабочего места сохраняем тем же upsert-ом: строка одна на
  /// месяц, и передать только ставку помощника нельзя — второе поле
  /// затёрлось бы значением по умолчанию.
  Future<void> setWorkplaceHelperCoefficient({
    required String workplaceId,
    required double? helperCoefficient,
    String? actorId,
  }) async {
    if (_permission?.canEdit != true) {
      throw StateError('У вас нет прав на изменение финансовых данных.');
    }
    await _coefficientsRepo.upsert(
      permission: _permission,
      workplaceId: workplaceId,
      coefficient: _state.coefficients[workplaceId] ?? 0,
      setHelperCoefficient: true,
      helperCoefficient: helperCoefficient,
      month: _state.month.firstDay,
      updatedBy: actorId,
    );
    final next = Map<String, double>.from(_state.helperCoefficients);
    if (helperCoefficient == null ||
        !helperCoefficient.isFinite ||
        helperCoefficient < 0) {
      next.remove(workplaceId);
    } else {
      next[workplaceId] = helperCoefficient;
    }
    _state = _state.copyWith(helperCoefficients: next);
    notifyListeners();
  }

  /// Сохраняет настройки оплаты.
  Future<void> saveSalarySettings({
    required double nightPercent,
    required double mealAmount,
    required double socialDefault,
    String? actorId,
  }) async {
    if (_permission?.canEdit != true) {
      throw StateError('У вас нет прав на изменение финансовых данных.');
    }
    final saved = await _salarySettingsRepo.save(
      permission: _permission,
      month: _state.month.firstDay,
      nightPercent: nightPercent,
      mealAmount: mealAmount,
      socialDefault: socialDefault,
      updatedBy: actorId,
    );
    _state = _state.copyWith(settings: saved);
    notifyListeners();
  }

  /// Сохраняет ручные корректировки зарплаты по сотруднику за месяц.
  ///
  /// Оптимистично применяет правку сразу (ввод не «прыгает» и таблица
  /// пересчитывает итоги без ожидания сети). Если upsert упал —
  /// откатываемся к прежним значениям и пробрасываем исключение, чтобы
  /// UI показал SnackBar.
  Future<void> saveSalaryAdjustments(SalaryAdjustments adj,
      {String? actorId}) async {
    if (_permission?.canEdit != true) {
      throw StateError('У вас нет прав на изменение финансовых данных.');
    }
    final previous = _state.adjustments;
    final optimistic = Map<String, SalaryAdjustments>.from(previous);
    optimistic[adj.employeeId] = adj;
    _state = _state.copyWith(adjustments: optimistic);
    notifyListeners();
    try {
      final saved = await _adjustmentsRepo.upsert(
        adj,
        permission: _permission,
        updatedBy: actorId,
      );
      final next = Map<String, SalaryAdjustments>.from(_state.adjustments);
      next[saved.employeeId] = saved;
      _state = _state.copyWith(adjustments: next);
      notifyListeners();
    } catch (e) {
      _state = _state.copyWith(adjustments: previous);
      notifyListeners();
      rethrow;
    }
  }

  /// Сохраняет ячейку графика.
  Future<void> saveScheduleCell({
    required String employeeId,
    required DateTime date,
    required WorkScheduleEntry entry,
    String? actorId,
  }) async {
    final saved = await _scheduleRepo.upsert(
      employeeId: employeeId,
      workDate: date,
      shiftType: entry.shiftType,
      arrivalTime: entry.arrivalTime,
      departureTime: entry.departureTime,
      updatedBy: actorId,
    );
    final next = Map<String, Map<int, WorkScheduleEntry>>.from(_state.schedules);
    final byDay = Map<int, WorkScheduleEntry>.from(next[employeeId] ?? const {});
    byDay[date.day] = saved;
    next[employeeId] = byDay;
    _state = _state.copyWith(schedules: next);
    notifyListeners();
  }

  // Статусами (создание/удаление/присвоение) управляет модуль персонала
  // (PersonnelProvider) — он владелец записи. Аналитика только читает
  // статусы/историю для отображения и расчёта ЗП (см. _loadMonthOnce).

  Future<void> setEmployeePayType({
    required String employeeId,
    required String? payType,
  }) async {
    await _payRepo.setPayType(employeeId, payType);
    final next = Map<String, String?>.from(_state.employeePayTypes);
    next[employeeId] = payType;
    _state = _state.copyWith(employeePayTypes: next);
    notifyListeners();
  }

  /// Сохраняет оклад за смену сотрудника (employees.base_day_salary).
  /// Оптимистично + откат при ошибке (как saveSalaryAdjustments).
  Future<void> setEmployeeBaseSalary({
    required String employeeId,
    required double value,
  }) async {
    if (_permission?.canEdit != true) {
      throw StateError('У вас нет прав на изменение финансовых данных.');
    }
    final previous = _state.employeeBaseSalaries;
    final optimistic = Map<String, double>.from(previous);
    optimistic[employeeId] = value;
    _state = _state.copyWith(employeeBaseSalaries: optimistic);
    notifyListeners();
    try {
      await _payRepo.setBaseDaySalary(employeeId, value);
    } catch (e) {
      _state = _state.copyWith(employeeBaseSalaries: previous);
      notifyListeners();
      rethrow;
    }
  }

  /// Сохраняет фиксированную ставку за смену по статусу на текущий месяц.
  Future<void> setStatusPayRate({
    required String statusId,
    required double fixedDayPay,
    String? actorId,
  }) async {
    if (_permission?.canEdit != true) {
      throw StateError('У вас нет прав на изменение финансовых данных.');
    }
    await _statusRateRepo.upsert(
      permission: _permission,
      statusId: statusId,
      fixedDayPay: fixedDayPay,
      month: _state.month.firstDay,
      updatedBy: actorId,
    );
    final next = Map<String, double>.from(_state.statusPayRates);
    next[statusId] = fixedDayPay;
    _state = _state.copyWith(statusPayRates: next);
    notifyListeners();
  }
}