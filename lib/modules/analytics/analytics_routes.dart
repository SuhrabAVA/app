import 'package:flutter/material.dart';

import 'analytics_module.dart';

class AnalyticsRoutes {
  AnalyticsRoutes._();

  static const String home = '/analytics';

  static Route<dynamic> buildHomeRoute({
    required bool isTechLeader,
    String? currentEmployeeId,
  }) {
    return MaterialPageRoute(
      settings: const RouteSettings(name: home),
      builder: (_) => AnalyticsEntry(
        isTechLeader: isTechLeader,
        currentEmployeeId: currentEmployeeId,
      ),
    );
  }
}
