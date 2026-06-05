import 'dart:async';

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
import 'analytics_access_denied_screen.dart';
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
  late TaskProvider _taskProvider;
  late OrdersProvider _ordersProvider;
  bool _bootstrapped = false;
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  Timer? _refreshDebounce;

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
      final personnelProvider = context.read<PersonnelProvider>();
      _ordersProvider = context.read<OrdersProvider>();
      _taskProvider = context.read<TaskProvider>();
      _service = AnalyticsService(
        personnel: personnelProvider,
        orders: _ordersProvider,
        tasks: _taskProvider,
        permission: widget.permission,
      );
      _service.loadMonth(AnalyticsMonth.current());
      // если пришла обновлённая база — перезагрузим аналитику.
      _taskProvider.addListener(_onProvidersChanged);
      _ordersProvider.addListener(_onProvidersChanged);
    }
  }

  void _onProvidersChanged() {
    if (!mounted) return;
    _refreshDebounce?.cancel();
    _refreshDebounce = Timer(const Duration(milliseconds: 800), () {
      if (mounted) _service.refresh();
    });
  }

  @override
  void dispose() {
    _refreshDebounce?.cancel();
    if (_bootstrapped) {
      _taskProvider.removeListener(_onProvidersChanged);
      _ordersProvider.removeListener(_onProvidersChanged);
      _service.dispose();
    }
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

        // Сотрудник без прав видит только свою деталку; прямые
        // маршруты в разделы списка/графиков/рабочих мест блокируются явно.
        if (!canViewAll && widget.initialTab != AnalyticsTopTab.employees) {
          return const AnalyticsAccessDeniedScreen();
        }

        if (!canViewAll) {
          if (permission.currentEmployeeId == null) {
            return const AnalyticsAccessDeniedScreen();
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
    // filter-group: подпись сверху, контрол снизу (как в .filters-card).
    final monthGroup = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Месяц',
            style: TextStyle(color: AnalyticsColors.muted, fontSize: 12)),
        const SizedBox(height: 8),
        AnalyticsMonthPicker(
          month: month,
          onChanged: (m) => _service.loadMonth(m),
        ),
      ],
    );

    final settingsButton = widget.permission.canViewFinance
        ? TextButton.icon(
            onPressed: () => _scaffoldKey.currentState?.openEndDrawer(),
            style: TextButton.styleFrom(
              minimumSize: const Size(0, 42),
              padding: const EdgeInsets.symmetric(horizontal: 18),
              foregroundColor: AnalyticsColors.text,
              backgroundColor: const Color(0xBF0F172A),
              side: const BorderSide(color: AnalyticsColors.line),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(999),
              ),
            ),
            icon: const Icon(Icons.tune, size: 18),
            label: const Text('Настройки оплаты'),
          )
        : null;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xB80F172A),
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: AnalyticsColors.line),
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            if (constraints.maxWidth < 560) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  monthGroup,
                  if (settingsButton != null) ...[
                    const SizedBox(height: 12),
                    settingsButton,
                  ],
                ],
              );
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                monthGroup,
                const Spacer(),
                if (settingsButton != null) settingsButton,
              ],
            );
          },
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