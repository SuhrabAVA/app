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
import '../widgets/employees_table.dart';
import '../widgets/salary_settings_drawer.dart';
import '../widgets/schedule_grid.dart';
import '../widgets/workplaces_table.dart';
import 'employee_detail_screen.dart';
import 'workplace_detail_screen.dart';

class AnalyticsHomeScreen extends StatefulWidget {
  const AnalyticsHomeScreen({super.key, required this.permission});
  final AnalyticsPermissionService permission;

  @override
  State<AnalyticsHomeScreen> createState() => _AnalyticsHomeScreenState();
}

class _AnalyticsHomeScreenState extends State<AnalyticsHomeScreen> {
  AnalyticsTopTab _tab = AnalyticsTopTab.employees;
  late AnalyticsService _service;
  bool _bootstrapped = false;
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  // Отдельные контроллеры на каждую вкладку — чтобы Scrollbar и
  // SingleChildScrollView всегда использовали один и тот же controller
  // и не пытались хватать PrimaryScrollController.
  late final ScrollController _scrollEmployees;
  late final ScrollController _scrollWorkplaces;
  late final ScrollController _scrollSchedule;

  @override
  void initState() {
    super.initState();
    _scrollEmployees = ScrollController();
    _scrollWorkplaces = ScrollController();
    _scrollSchedule = ScrollController();
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
    _scrollEmployees.dispose();
    _scrollWorkplaces.dispose();
    _scrollSchedule.dispose();
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
              Expanded(
                child: state.loading
                    ? const AnalyticsLoadingState()
                    : state.error != null
                        ? AnalyticsErrorState(
                            message:
                                'Не удалось загрузить аналитику.\n${state.error}',
                            onRetry: () => _service.refresh(),
                          )
                        : _content(state),
              ),
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

  Widget _content(state) {
    switch (_tab) {
      case AnalyticsTopTab.employees:
        return _scrollable(
          controller: _scrollEmployees,
          child: EmployeesTable(
            service: _service,
            personnel: context.read<PersonnelProvider>(),
            canViewFinance: widget.permission.canViewFinance,
            onEmployeeTap: (id) {
              Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => EmployeeDetailScreen(
                  service: _service,
                  permission: widget.permission,
                  employeeId: id,
                ),
              ));
            },
          ),
        );
      case AnalyticsTopTab.workplaces:
        return _scrollable(
          controller: _scrollWorkplaces,
          child: WorkplacesTable(
            service: _service,
            personnel: context.read<PersonnelProvider>(),
            canEditCoefficient: widget.permission.canEdit,
            onWorkplaceTap: (id) {
              Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => WorkplaceDetailScreen(
                  service: _service,
                  permission: widget.permission,
                  workplaceId: id,
                ),
              ));
            },
          ),
        );
      case AnalyticsTopTab.schedule:
        return _scrollable(
          controller: _scrollSchedule,
          child: ScheduleGrid(
            service: _service,
            personnel: context.read<PersonnelProvider>(),
            canEdit: widget.permission.canEdit,
          ),
        );
    }
  }

  Widget _scrollable({
    required Widget child,
    required ScrollController controller,
  }) =>
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Container(
          // Bounded height приходит сверху от Expanded -> Padding -> Container.
          // Scrollbar и SingleChildScrollView используют ОДИН ScrollController,
          // primary: false — чтобы не цепляться за PrimaryScrollController.
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
