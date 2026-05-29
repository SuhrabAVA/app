import 'package:flutter/material.dart';

import 'analytics_module.dart';
import 'widgets/analytics_topbar.dart';

class AnalyticsRoutes {
  AnalyticsRoutes._();

  static const String home = '/analytics';
  static const String employees = '/analytics/employees';
  static const String workplaces = '/analytics/workplaces';
  static const String schedule = '/analytics/schedule';

  static Route<dynamic> buildHomeRoute({
    required bool isTechLeader,
    String? currentEmployeeId,
    AnalyticsTopTab initialTab = AnalyticsTopTab.employees,
  }) {
    return MaterialPageRoute(
      settings: RouteSettings(name: routeNameForTab(initialTab)),
      builder: (_) => AnalyticsEntry(
        isTechLeader: isTechLeader,
        currentEmployeeId: currentEmployeeId,
        initialTab: initialTab,
      ),
    );
  }

  static Route<dynamic> buildEmployeesRoute({
    required bool isTechLeader,
    String? currentEmployeeId,
  }) {
    return buildHomeRoute(
      isTechLeader: isTechLeader,
      currentEmployeeId: currentEmployeeId,
      initialTab: AnalyticsTopTab.employees,
    );
  }

  static Route<dynamic> buildWorkplacesRoute({
    required bool isTechLeader,
    String? currentEmployeeId,
  }) {
    return buildHomeRoute(
      isTechLeader: isTechLeader,
      currentEmployeeId: currentEmployeeId,
      initialTab: AnalyticsTopTab.workplaces,
    );
  }

  static Route<dynamic> buildScheduleRoute({
    required bool isTechLeader,
    String? currentEmployeeId,
  }) {
    return buildHomeRoute(
      isTechLeader: isTechLeader,
      currentEmployeeId: currentEmployeeId,
      initialTab: AnalyticsTopTab.schedule,
    );
  }

  static String routeNameForTab(AnalyticsTopTab tab) {
    switch (tab) {
      case AnalyticsTopTab.employees:
        return employees;
      case AnalyticsTopTab.workplaces:
        return workplaces;
      case AnalyticsTopTab.schedule:
        return schedule;
    }
  }
}
