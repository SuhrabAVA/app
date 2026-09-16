import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../services/realtime_sync_service.dart';
import '../../orders/orders_provider.dart';
import '../../personnel/personnel_provider.dart';
import '../../tasks/task_provider.dart';
import '../models/analytics_month.dart';
import '../services/analytics_permission_service.dart';
import '../services/analytics_service.dart';
import '../utils/analytics_colors.dart';
import '../widgets/analytics_month_picker.dart';
import '../widgets/analytics_shell.dart';
import '../widgets/analytics_topbar.dart';
import '../widgets/salary_settings_drawer.dart';
import 'analytics_access_denied_screen.dart';
import 'employee_detail_screen.dart';
import 'employees_analytics_screen.dart';
import 'status_staff_analytics_screen.dart';
import 'work_schedule_screen.dart';
import 'workplaces_analytics_screen.dart';

class AnalyticsHomeScreen extends StatefulWidget {
  const AnalyticsHomeScreen({
    super.key,
    required this.permission,
    this.initialTab = AnalyticsTopTab.employees,
    this.selfViewCanGoBack = false,
  });

  final AnalyticsPermissionService permission;
  final AnalyticsTopTab initialTab;

  /// true, когда selfView открыт push-ем поверх рабочего пространства и
  /// сотруднику нужна ссылка «Назад». Из админ-панели флаг не передаётся:
  /// там экран встроен и back-ссылка попнула бы весь маршрут панели.
  final bool selfViewCanGoBack;

  @override
  State<AnalyticsHomeScreen> createState() => _AnalyticsHomeScreenState();
}

class _AnalyticsHomeScreenState extends State<AnalyticsHomeScreen> {
  late AnalyticsTopTab _tab;
  late AnalyticsService _service;
  late TaskProvider _taskProvider;
  late OrdersProvider _ordersProvider;
  late PersonnelProvider _personnelProvider;
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
      _personnelProvider = personnelProvider;
      _ordersProvider = context.read<OrdersProvider>();
      _taskProvider = context.read<TaskProvider>();
      _service = AnalyticsService(
        personnel: personnelProvider,
        orders: _ordersProvider,
        tasks: _taskProvider,
        permission: widget.permission,
      );
      RealtimeSyncService.instance.registerRefreshHandler(
        owner: this,
        resource: RealtimeResource.analytics,
        handler: _service.refresh,
      );
      _service.loadMonth(AnalyticsMonth.current());
      // если пришла обновлённая база — перезагрузим аналитику.
      _taskProvider.addListener(_onProvidersChanged);
      _ordersProvider.addListener(_onProvidersChanged);
      _personnelProvider.addListener(_onProvidersChanged);
    }
  }

  void _onProvidersChanged() {
    if (!mounted) return;
    _refreshDebounce?.cancel();
    // TaskProvider/OrdersProvider уведомляют на каждое realtime-событие.
    // Рефреш «тихий» (см. AnalyticsService) и таблицу не пересоздаёт, но
    // каждый refresh — пакет запросов к Supabase; 2 с собирают всплеск
    // событий в один рефреш, не задерживая данные заметно для глаза.
    _refreshDebounce = Timer(const Duration(seconds: 2), () {
      if (mounted) _service.refresh();
    });
  }

  @override
  void dispose() {
    _refreshDebounce?.cancel();
    if (_bootstrapped) {
      RealtimeSyncService.instance.unregisterOwner(this);
      _taskProvider.removeListener(_onProvidersChanged);
      _ordersProvider.removeListener(_onProvidersChanged);
      _personnelProvider.removeListener(_onProvidersChanged);
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
            hideBackButton: !widget.selfViewCanGoBack,
            onMonthChanged: (m) => _service.loadMonth(m),
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
        const SizedBox(height: 4),
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
              minimumSize: const Size(0, 36),
              padding: const EdgeInsets.symmetric(horizontal: 14),
              foregroundColor: AnalyticsColors.text,
              backgroundColor: AnalyticsColors.bg2,
              side: const BorderSide(color: AnalyticsColors.line),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            icon: const Icon(Icons.tune, size: 18),
            label: const Text('Настройки оплаты'),
          )
        : null;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: AnalyticsColors.card,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AnalyticsColors.line),
          boxShadow: const [
            BoxShadow(
              color: Color(0x12000000),
              blurRadius: 10,
              offset: Offset(0, 2),
            ),
          ],
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            if (constraints.maxWidth < 560) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  monthGroup,
                  if (settingsButton != null) ...[
                    const SizedBox(height: 8),
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
        StatusStaffAnalyticsScreen(
          service: _service,
          permission: widget.permission,
        ),
      ],
    );
  }
}
