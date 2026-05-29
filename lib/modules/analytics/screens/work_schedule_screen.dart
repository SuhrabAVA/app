import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../personnel/personnel_provider.dart';
import '../services/analytics_permission_service.dart';
import '../services/analytics_service.dart';
import '../utils/analytics_colors.dart';
import '../widgets/analytics_states.dart';
import '../widgets/schedule_grid.dart';

class WorkScheduleScreen extends StatefulWidget {
  const WorkScheduleScreen({
    super.key,
    required this.service,
    required this.permission,
  });

  final AnalyticsService service;
  final AnalyticsPermissionService permission;

  @override
  State<WorkScheduleScreen> createState() => _WorkScheduleScreenState();
}

class _WorkScheduleScreenState extends State<WorkScheduleScreen> {
  late final ScrollController _scrollController;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.service,
      builder: (context, _) {
        final state = widget.service.state;
        if (state.loading) {
          return const AnalyticsLoadingState(label: 'Загружаем график работы…');
        }
        if (state.error != null) {
          return AnalyticsErrorState(
            message: 'Не удалось загрузить график работы.\n${state.error}',
            onRetry: () => widget.service.refresh(),
          );
        }

        final personnel = context.read<PersonnelProvider>();
        final activeEmployees = personnel.employees.where((e) => !e.isFired);
        if (activeEmployees.isEmpty) {
          return const AnalyticsEmptyState(
            icon: Icons.calendar_month_outlined,
            message: 'Нет активных сотрудников для графика работы.',
          );
        }

        return _AnalyticsTableCard(
          controller: _scrollController,
          child: ScheduleGrid(
            service: widget.service,
            personnel: personnel,
            canEdit: widget.permission.canEdit,
          ),
        );
      },
    );
  }
}

class _AnalyticsTableCard extends StatelessWidget {
  const _AnalyticsTableCard({
    required this.controller,
    required this.child,
  });

  final ScrollController controller;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Container(
        decoration: BoxDecoration(
          color: AnalyticsColors.card,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: AnalyticsColors.line),
        ),
        clipBehavior: Clip.antiAlias,
        child: Scrollbar(
          controller: controller,
          thumbVisibility: true,
          child: SingleChildScrollView(
            controller: controller,
            primary: false,
            child: child,
          ),
        ),
      ),
    );
  }
}
