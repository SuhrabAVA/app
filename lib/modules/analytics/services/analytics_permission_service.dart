import 'package:supabase_flutter/supabase_flutter.dart';

import '../../personnel/employee_model.dart';
import '../../personnel/personnel_constants.dart';

/// Управление правами доступа к аналитике.
///
/// Источник прав не должен ограничиваться входным bool из UI: сервис умеет
/// поднимать роль из доверенного Supabase-профиля текущего пользователя
/// (app/user metadata и таблицы ролей/профилей) и только затем применять
/// локальный fallback по должности сотрудника.
///
/// - Технический лидер (positionId == kTechLeaderId) или роль
///   `lead` / `tech_lead` / `tech_leader` — полный доступ.
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

  /// Единая проверка для всех финансовых write-операций.
  void ensureCanEditFinance() {
    if (!canEdit) {
      throw StateError('У вас нет прав на изменение финансовых данных.');
    }
  }

  /// Фабрика на основе уже загруженных локальных данных профиля.
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

  /// Собирает права из Supabase и локального fallback.
  ///
  /// Поддержаны несколько распространённых схем хранения ролей, чтобы модуль
  /// не зависел от конкретного названия таблицы в проекте:
  /// - `auth.users.app_metadata/user_metadata.role`;
  /// - `user_roles` с колонками `user_id`, `role`;
  /// - `profiles` с колонками `id`, `role`;
  /// - `employee_roles` с колонками `employee_id`, `role`.
  static Future<AnalyticsPermissionService> fromTrustedSupabaseContext({
    required bool fallbackIsTechLeader,
    required String? currentEmployeeId,
    SupabaseClient? client,
  }) async {
    final supabase = client ?? Supabase.instance.client;
    final user = supabase.auth.currentUser;
    var trustedLead = fallbackIsTechLeader;

    trustedLead = trustedLead || _isLeadRole(user?.appMetadata?['role']);
    trustedLead = trustedLead || _isLeadRole(user?.userMetadata?['role']);

    if (user != null && !trustedLead) {
      trustedLead = await _hasRoleInTable(
        client: supabase,
        table: 'user_roles',
        idColumn: 'user_id',
        id: user.id,
      );
    }
    if (user != null && !trustedLead) {
      trustedLead = await _hasRoleInTable(
        client: supabase,
        table: 'profiles',
        idColumn: 'id',
        id: user.id,
      );
    }
    final employeeId = currentEmployeeId?.trim();
    if (!trustedLead && employeeId != null && employeeId.isNotEmpty) {
      trustedLead = await _hasRoleInTable(
        client: supabase,
        table: 'employee_roles',
        idColumn: 'employee_id',
        id: employeeId,
      );
    }

    return AnalyticsPermissionService(
      isTechLeader: trustedLead,
      currentEmployeeId: currentEmployeeId,
    );
  }

  static Future<bool> _hasRoleInTable({
    required SupabaseClient client,
    required String table,
    required String idColumn,
    required String id,
  }) async {
    try {
      final rows = await client
          .from(table)
          .select('role')
          .eq(idColumn, id)
          .limit(20);
      if (rows is! List) return false;
      return rows.any((row) {
        if (row is! Map) return false;
        return _isLeadRole(row['role']);
      });
    } on PostgrestException {
      return false;
    } catch (_) {
      return false;
    }
  }

  static bool _isLeadRole(Object? rawRole) {
    final role = rawRole?.toString().trim().toLowerCase();
    return role == 'lead' || role == 'tech_lead' || role == 'tech_leader';
  }
}
