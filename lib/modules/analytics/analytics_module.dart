/// Точка входа в модуль аналитики.
///
/// Используется из главного меню:
/// ```dart
/// Navigator.of(context).push(MaterialPageRoute(
///   builder: (_) => AnalyticsEntry(
///     isTechLeader: AuthHelper.isTechLeader(),
///   ),
/// ));
/// ```
library analytics_module;

import 'package:flutter/material.dart';

import 'screens/analytics_home_screen.dart';
import 'services/analytics_permission_service.dart';
import 'widgets/analytics_topbar.dart';

class AnalyticsEntry extends StatelessWidget {
  const AnalyticsEntry({
    super.key,
    required this.isTechLeader,
    this.currentEmployeeId,
    this.initialTab = AnalyticsTopTab.employees,
  });

  /// true если у текущего пользователя роль «Технический лидер»
  /// (полный доступ к финансам и редактированию).
  final bool isTechLeader;

  /// id сотрудника, под которым выполнен вход. Если null — обычный
  /// сотрудник без доступа к аналитике.
  final String? currentEmployeeId;

  /// Вкладка, которую нужно открыть при входе в аналитику.
  final AnalyticsTopTab initialTab;

  @override
  Widget build(BuildContext context) {
    final permission = AnalyticsPermissionService(
      isTechLeader: isTechLeader,
      currentEmployeeId: currentEmployeeId,
    );
    return AnalyticsHomeScreen(
      permission: permission,
      initialTab: initialTab,
    );
  }
}
