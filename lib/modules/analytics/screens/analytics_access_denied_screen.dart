import 'package:flutter/material.dart';

import '../widgets/analytics_shell.dart';
import '../widgets/analytics_states.dart';

/// Явный экран для маршрутов аналитики, которые недоступны текущему пользователю.
class AnalyticsAccessDeniedScreen extends StatelessWidget {
  const AnalyticsAccessDeniedScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const AnalyticsShell(
      child: Center(child: AnalyticsAccessDeniedState()),
    );
  }
}
