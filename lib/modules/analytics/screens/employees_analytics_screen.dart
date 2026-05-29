import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../personnel/personnel_provider.dart';
import '../services/analytics_permission_service.dart';
import '../services/analytics_service.dart';
import '../utils/analytics_colors.dart';
import '../widgets/analytics_states.dart';
import '../widgets/employees_table.dart';
import 'employee_detail_screen.dart';

class EmployeesAnalyticsScreen extends StatefulWidget {
  const EmployeesAnalyticsScreen({
    super.key,
    required this.service,
    required this.permission,
  });

  final AnalyticsService service;
  final AnalyticsPermissionService permission;

  @override
  State<EmployeesAnalyticsScreen> createState() =>
      _EmployeesAnalyticsScreenState();
}

class _EmployeesAnalyticsScreenState extends State<EmployeesAnalyticsScreen> {
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
          return const AnalyticsLoadingState();
        }
        if (state.error != null) {
          return AnalyticsErrorState(
            message:
                'Не удалось загрузить аналитику сотрудников.\n${state.error}',
            onRetry: () => widget.service.refresh(),
          );
        }

        final personnel = context.read<PersonnelProvider>();
        final activeEmployees = personnel.employees.where((e) => !e.isFired);
        if (activeEmployees.isEmpty) {
          return const AnalyticsEmptyState(
            icon: Icons.people_outline,
            message: 'Нет активных сотрудников для выбранного месяца.',
          );
        }

        return _AnalyticsTableCard(
          controller: _scrollController,
          child: EmployeesTable(
            service: widget.service,
            personnel: personnel,
            canViewFinance: widget.permission.canViewFinance,
            onEmployeeTap: (id) {
              Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => EmployeeDetailScreen(
                  service: widget.service,
                  permission: widget.permission,
                  employeeId: id,
                ),
              ));
            },
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
