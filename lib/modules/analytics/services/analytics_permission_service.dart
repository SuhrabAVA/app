import '../../personnel/employee_model.dart';
import '../../personnel/personnel_constants.dart';

/// Управление правами доступа к аналитике.
///
/// - Технический лидер (positionId == kTechLeaderId) или флаг
///   userMetadata.role == 'lead' / 'tech_leader' — полный доступ.
/// - Иначе обычный сотрудник: видит только себя, без финансов.
class AnalyticsPermissionService {
  AnalyticsPermissionService({
    required this.isTechLeader,
    required this.currentEmployeeId,
  });

  /// true, если текущий пользователь — Технический лидер.
  final bool isTechLeader;
  /// id сотрудника, под которым выполнен вход (или null).
  final String? currentEmployeeId;

  /// Может ли видеть полную таблицу сотрудников.
  bool get canViewAllEmployees => isTechLeader;

  /// Может ли видеть финансовые данные.
  bool get canViewFinance => isTechLeader;

  /// Может ли редактировать графики, коэффициенты, удержания.
  bool get canEdit => isTechLeader;

  /// Может ли видеть детальную страницу конкретного сотрудника.
  bool canViewEmployee(String employeeId) {
    if (isTechLeader) return true;
    if (currentEmployeeId == null) return false;
    return currentEmployeeId == employeeId;
  }

  /// Фабрика на основе данных профиля.
  factory AnalyticsPermissionService.fromContext({
    required bool isTechLeaderRole,
    EmployeeModel? employee,
    List<String> positionIds = const [],
  }) {
    final hasTechLeaderPosition = positionIds.contains(kTechLeaderId);
    return AnalyticsPermissionService(
      isTechLeader: isTechLeaderRole || hasTechLeaderPosition,
      currentEmployeeId: employee?.id,
    );
  }
}
