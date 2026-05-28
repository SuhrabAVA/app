import 'package:flutter/foundation.dart';

import '../../orders/order_model.dart';
import '../../orders/orders_provider.dart';
import '../../personnel/personnel_provider.dart';
import '../../tasks/task_provider.dart';
import '../models/analytics_event.dart';
import '../models/analytics_month.dart';
import '../models/claim_model.dart';
import '../models/employee_status.dart';
import '../models/salary_adjustments.dart';
import '../models/salary_settings.dart';
import '../models/work_schedule_entry.dart';
import '../repositories/analytics_repository.dart';
import '../repositories/claims_repository.dart';
import '../repositories/employee_status_repository.dart';
import '../repositories/salary_adjustments_repository.dart';
import '../repositories/salary_settings_repository.dart';
import '../repositories/work_schedule_repository.dart';
import '../repositories/workplace_coefficient_repository.dart';

/// Состояние данных аналитики на выбранный месяц.
class AnalyticsState {
  final AnalyticsMonth month;
  final List<AnalyticsEvent> events;
  final Map<String, double> coefficients;
  final SalarySettings settings;
  final Map<String, SalaryAdjustments> adjustments;
  final Map<String, Map<int, WorkScheduleEntry>> schedules;
  final List<EmployeeStatus> statuses;
  final Map<String, String> employeeStatusIds;
  final Map<String, String?> employeePayTypes;
  final List<ClaimModel> claims;
  /// Скорости рабочих мест за каждый из предыдущих месяцев (от 1 до 12).
  /// Используется для расчёта КПД.
  final Map<String, List<double>> workplacePreviousSpeeds;
  final bool loading;
  final Object? error;

  AnalyticsState({
    required this.month,
    this.events = const [],
    this.coefficients = const {},
    SalarySettings? settings,
    this.adjustments = const {},
    this.schedules = const {},
    this.statuses = const [],
    this.employeeStatusIds = const {},
    this.employeePayTypes = const {},
    this.claims = const [],
    this.workplacePreviousSpeeds = const {},
    this.loading = false,
    this.error,
  }) : settings = settings ?? SalarySettings.defaults(month.firstDay);

  AnalyticsState copyWith({
    AnalyticsMonth? month,
    List<AnalyticsEvent>? events,
    Map<String, double>? coefficients,
    SalarySettings? settings,
    Map<String, SalaryAdjustments>? adjustments,
    Map<String, Map<int, WorkScheduleEntry>>? schedules,
    List<EmployeeStatus>? statuses,
    Map<String, String>? employeeStatusIds,
    Map<String, String?>? employeePayTypes,
    List<ClaimModel>? claims,
    Map<String, List<double>>? workplacePreviousSpeeds,
    bool? loading,
    Object? error,
    bool clearError = false,
  }) {
    return AnalyticsState(
      month: month ?? this.month,
      events: events ?? this.events,
      coefficients: coefficients ?? this.coefficients,
      settings: settings ?? this.settings,
      adjustments: adjustments ?? this.adjustments,
      schedules: schedules ?? this.schedules,
      statuses: statuses ?? this.statuses,
      employeeStatusIds: employeeStatusIds ?? this.employeeStatusIds,
      employeePayTypes: employeePayTypes ?? this.employeePayTypes,
      claims: claims ?? this.claims,
      workplacePreviousSpeeds:
          workplacePreviousSpeeds ?? this.workplacePreviousSpeeds,
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
    ClaimsRepository? claimsRepo,
    AnalyticsRepository? analyticsRepo,
  })  : _coefficientsRepo = coefficientsRepo ?? WorkplaceCoefficientRepository(),
        _salarySettingsRepo = salarySettingsRepo ?? SalarySettingsRepository(),
        _adjustmentsRepo = adjustmentsRepo ?? SalaryAdjustmentsRepository(),
        _scheduleRepo = scheduleRepo ?? WorkScheduleRepository(),
        _statusRepo = statusRepo ?? EmployeeStatusRepository(),
        _claimsRepo = claimsRepo ?? ClaimsRepository(),
        _analyticsRepo = analyticsRepo ?? AnalyticsRepository();

  final PersonnelProvider personnel;
  final OrdersProvider orders;
  final TaskProvider tasks;

  final WorkplaceCoefficientRepository _coefficientsRepo;
  final SalarySettingsRepository _salarySettingsRepo;
  final SalaryAdjustmentsRepository _adjustmentsRepo;
  final WorkScheduleRepository _scheduleRepo;
  final EmployeeStatusRepository _statusRepo;
  final ClaimsRepository _claimsRepo;
  final AnalyticsRepository _analyticsRepo;

  AnalyticsState _state =
      AnalyticsState(month: AnalyticsMonth.current(), loading: true);
  AnalyticsState get state => _state;

  Future<void> loadMonth(AnalyticsMonth month) async {
    _state = _state.copyWith(month: month, loading: true, clearError: true);
    notifyListeners();
    try {
      // 1. Заказы по id для customer.
      final ordersById = <String, OrderModel>{
        for (final o in orders.orders) o.id: o,
      };

      // 2. События аналитики на текущий месяц.
      final events = _analyticsRepo.buildEvents(
        tasks: tasks.tasks,
        ordersById: ordersById,
        month: month,
      );

      // 3. Settings, coefficients, adjustments, schedules, claims.
      final coeffsFuture = _coefficientsRepo.loadEffective(month.firstDay);
      final settingsFuture =
          _salarySettingsRepo.loadEffective(month.firstDay);
      final adjustmentsFuture =
          _adjustmentsRepo.loadForMonth(month.firstDay);
      final schedulesFuture =
          _scheduleRepo.loadForMonth(month.firstDay);
      final statusesFuture = _statusRepo.listAll();
      final employeeStatusIdsFuture = _statusRepo.loadEmployeeStatusIds();
      final employeePayTypesFuture = _statusRepo.loadEmployeePayTypes();
      final claimsFuture = _claimsRepo.listForMonth(month.firstDay);

      final coeffs = await coeffsFuture;
      final settings = await settingsFuture;
      final adjustments = await adjustmentsFuture;
      final schedules = await schedulesFuture;
      final statuses = await statusesFuture;
      final empStatusIds = await employeeStatusIdsFuture;
      final empPayTypes = await employeePayTypesFuture;
      final claims = await claimsFuture;

      // 4. Скорости предыдущих месяцев — для КПД (3 предыдущих месяца).
      final prevMonths = month.previousMonths(3);
      final prevSpeeds = <String, List<double>>{};
      for (final prev in prevMonths) {
        final prevEvents = _analyticsRepo.buildEvents(
          tasks: tasks.tasks,
          ordersById: ordersById,
          month: prev,
        );
        final byWorkplace = <String, List<AnalyticsEvent>>{};
        for (final e in prevEvents) {
          if (e.type != AnalyticsEventType.work) continue;
          byWorkplace.putIfAbsent(e.workplaceId, () => []).add(e);
        }
        byWorkplace.forEach((wpId, list) {
          final qty = list.fold<double>(0, (s, e) => s + e.qty);
          final minutes = list.fold<int>(0, (s, e) => s + e.durationMinutes());
          if (minutes <= 0) return;
          final speed = qty / minutes;
          prevSpeeds.putIfAbsent(wpId, () => []).add(speed);
        });
      }

      _state = AnalyticsState(
        month: month,
        events: events,
        coefficients: coeffs,
        settings: settings,
        adjustments: adjustments,
        schedules: schedules,
        statuses: statuses,
        employeeStatusIds: empStatusIds,
        employeePayTypes: empPayTypes,
        claims: claims,
        workplacePreviousSpeeds: prevSpeeds,
        loading: false,
      );
      notifyListeners();
    } catch (e) {
      _state = _state.copyWith(loading: false, error: e);
      notifyListeners();
    }
  }

  Future<void> refresh() => loadMonth(_state.month);

  /// Сохраняет коэффициент рабочего места на текущий месяц.
  Future<void> setWorkplaceCoefficient({
    required String workplaceId,
    required double coefficient,
    String? actorId,
  }) async {
    await _coefficientsRepo.upsert(
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

  /// Сохраняет настройки оплаты.
  Future<void> saveSalarySettings({
    required double nightPercent,
    required double mealAmount,
    required double socialDefault,
    String? actorId,
  }) async {
    final saved = await _salarySettingsRepo.save(
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
  Future<void> saveSalaryAdjustments(SalaryAdjustments adj,
      {String? actorId}) async {
    final saved = await _adjustmentsRepo.upsert(adj, updatedBy: actorId);
    final next = Map<String, SalaryAdjustments>.from(_state.adjustments);
    next[saved.employeeId] = saved;
    _state = _state.copyWith(adjustments: next);
    notifyListeners();
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

  /// Создаёт новый статус.
  Future<EmployeeStatus> createStatus({
    required String name,
    String? description,
    String? color,
  }) async {
    final created = await _statusRepo.create(
        name: name, description: description, color: color);
    _state = _state.copyWith(
      statuses: [..._state.statuses, created],
    );
    notifyListeners();
    return created;
  }

  Future<void> assignStatusToEmployee(
      {required String employeeId, required String? statusId}) async {
    await _statusRepo.assignToEmployee(employeeId, statusId);
    final next = Map<String, String>.from(_state.employeeStatusIds);
    if (statusId == null || statusId.isEmpty) {
      next.remove(employeeId);
    } else {
      next[employeeId] = statusId;
    }
    _state = _state.copyWith(employeeStatusIds: next);
    notifyListeners();
  }

  Future<void> setEmployeePayType({
    required String employeeId,
    required String? payType,
  }) async {
    await _statusRepo.setPayType(employeeId, payType);
    final next = Map<String, String?>.from(_state.employeePayTypes);
    next[employeeId] = payType;
    _state = _state.copyWith(employeePayTypes: next);
    notifyListeners();
  }
}
