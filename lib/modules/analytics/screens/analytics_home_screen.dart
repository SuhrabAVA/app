import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../orders/orders_provider.dart';
import '../../personnel/personnel_provider.dart';
import '../../tasks/task_provider.dart';
import '../models/analytics_month.dart';
import '../services/analytics_permission_service.dart';
import '../services/analytics_service.dart';
import '../utils/analytics_colors.dart';
import '../widgets/analytics_month_picker.dart';
import '../widgets/analytics_shell.dart';
import '../widgets/analytics_states.dart';
import '../widgets/analytics_topbar.dart';
import '../widgets/salary_settings_drawer.dart';
import 'employee_detail_screen.dart';
import 'employees_analytics_screen.dart';
import 'work_schedule_screen.dart';
import 'workplaces_analytics_screen.dart';

class AnalyticsHomeScreen extends StatefulWidget {
  const AnalyticsHomeScreen({
    super.key,
    required this.permission,
    this.initialTab = AnalyticsTopTab.employees,
  });

  final AnalyticsPermissionService permission;
  final AnalyticsTopTab initialTab;

  @override
  State<AnalyticsHomeScreen> createState() => _AnalyticsHomeScreenState();
}

class _AnalyticsHomeScreenState extends State<AnalyticsHomeScreen> {
  late AnalyticsTopTab _tab;
  late AnalyticsService _service;
  bool _bootstrapped = false;
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  @override
  void initState() {
    super.initState();
    _tab = widget.initialTab;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_bootstrapped) {
      _bootstrapped = true;
      _service = AnalyticsService(
        personnel: context.read<PersonnelProvider>(),
        orders: context.read<OrdersProvider>(),
        tasks: context.read<TaskProvider>(),
      );
      _service.loadMonth(AnalyticsMonth.current());
      // если пришла обновлённая база — перезагрузим аналитику.
      context.read<TaskProvider>().addListener(_onProvidersChanged);
      context.read<OrdersProvider>().addListener(_onProvidersChanged);
    }
  }

  void _onProvidersChanged() {
    if (!mounted) return;
    _service.refresh();
  }

  @override
  void dispose() {
    context.read<TaskProvider>().removeListener(_onProvidersChanged);
    context.read<OrdersProvider>().removeListener(_onProvidersChanged);
    _service.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final permission = widget.permission;
    return AnimatedBuilder(
      animation: _service,
      builder: (context, _) {
        final state = _service.state;
        final canViewAll = permission.canViewAllEmployees;

        // Сотрудник без прав видит только свою деталку.
        if (!canViewAll) {
          if (permission.currentEmployeeId == null) {
            return const AnalyticsShell(
                child: Center(child: AnalyticsAccessDeniedState()));
          }
          // Сразу подсунем деталку сотрудника.
          return EmployeeDetailScreen(
            service: _service,
            permission: permission,
            employeeId: permission.currentEmployeeId!,
            hideBackButton: true,
          );
        }

        return AnalyticsShell(
          scaffoldKey: _scaffoldKey,
          endDrawer: SalarySettingsDrawer(
            service: _service,
            personnel: context.read<PersonnelProvider>(),
            canEdit: permission.canEdit,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AnalyticsTopbar(
                selected: _tab,
                onTabChanged: (t) => setState(() => _tab = t),
                onBack: () => Navigator.of(context).maybePop(),
              ),
              _filtersBar(state.month),
              Expanded(child: _content()),
            ],
          ),
        );
      },
    );
  }

  Widget _filtersBar(AnalyticsMonth month) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AnalyticsColors.card,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: AnalyticsColors.line),
        ),
        // Wrap не позволяет блокам выехать за край, если окно узкое.
        child: Wrap(
          spacing: 12,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Месяц:',
                    style: TextStyle(
                        color: AnalyticsColors.muted, fontSize: 12)),
                const SizedBox(width: 10),
                AnalyticsMonthPicker(
                  month: month,
                  onChanged: (m) => _service.loadMonth(m),
                ),
              ],
            ),
            if (widget.permission.canViewFinance)
              FilledButton.icon(
                icon: const Icon(Icons.tune),
                label: const Text('Настройки оплаты'),
                onPressed: () => _scaffoldKey.currentState?.openEndDrawer(),
              ),
          ],
        ),
      ),
    );
  }

  Widget _content() {
    return IndexedStack(
      index: _tab.index,
      sizing: StackFit.expand,
      children: [
        EmployeesAnalyticsScreen(
          service: _service,
          permission: widget.permission,
        ),
        WorkplacesAnalyticsScreen(
          service: _service,
          permission: widget.permission,
        ),
        WorkScheduleScreen(
          service: _service,
          permission: widget.permission,
        ),
      ],
    );
  }
}
