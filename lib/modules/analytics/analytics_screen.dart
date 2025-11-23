import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../personnel/personnel_provider.dart';
import '../personnel/employee_model.dart';
import '../orders/orders_provider.dart';
import '../orders/order_model.dart';
import '../warehouse/warehouse_table_styles.dart';

import 'analytics_provider.dart';
import 'analytics_record.dart';
import 'warehouse_analytics_tab.dart';

/// Экран отображения аналитики для разных категорий сотрудников.
/// Вверху — фильтры по сотруднику и периоду, ниже — вкладки:
/// производство / менеджеры / склад. Каждая вкладка показывает таблицу событий.
class AnalyticsScreen extends StatefulWidget {
  const AnalyticsScreen({super.key});

  @override
  State<AnalyticsScreen> createState() => _AnalyticsScreenState();
}

class _AnalyticsScreenState extends State<AnalyticsScreen> {
  String? _employeeId;
  DateTimeRange? _range;

  // ====== helpers ======

  String _employeeNames(PersonnelProvider personnel, String userIds) {
    final ids = userIds.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty);
    return ids.map((id) {
      try {
        final EmployeeModel e = personnel.employees.firstWhere((e) => e.id == id);
        return '${e.lastName} ${e.firstName}'.trim();
      } catch (_) {
        return id;
      }
    }).join(', ');
  }

  String _orderName(OrdersProvider orders, String id) {
    try {
      final OrderModel o = orders.orders.firstWhere((o) => o.id == id);
      final product = o.product.type;
      return product.isNotEmpty ? '${o.id} ($product)' : o.id;
    } catch (_) {
      return id;
    }
  }

  String _stageName(PersonnelProvider personnel, String id) {
    try {
      final stage = personnel.workplaces.firstWhere((w) => w.id == id);
      return stage.name;
    } catch (_) {
      return id;
    }
  }

  String _fmtTs(int ts) {
    final dt = DateTime.fromMillisecondsSinceEpoch(ts);
    return DateFormat('dd.MM.yyyy HH:mm:ss').format(dt);
  }

  String _localizeAction(String action) {
    switch (action) {
      case 'start':
        return 'Начало';
      case 'resume':
        return 'Возобновление';
      case 'pause':
        return 'Пауза';
      case 'finish':
        return 'Завершение';
      case 'problem':
        return 'Проблема';
      case 'login':
        return 'Вход';
      case 'logout':
        return 'Выход';
      case 'create':
        return 'Создание';
      case 'update':
        return 'Изменение';
      case 'delete':
        return 'Удаление';
      case 'inventory':
        return 'Инвентаризация';
      default:
        return action;
    }
  }

  List<AnalyticsRecord> _filterLogs(
    String category,
    List<AnalyticsRecord> logs,
  ) {
    return logs.where((r) {
      if (r.category != category) return false;

      if (_employeeId != null && _employeeId!.isNotEmpty) {
        final ids = r.userId.split(',').map((s) => s.trim());
        if (!ids.contains(_employeeId)) return false;
      }

      if (_range != null) {
        final start = DateTime(_range!.start.year, _range!.start.month, _range!.start.day).millisecondsSinceEpoch;
        final end = DateTime(_range!.end.year, _range!.end.month, _range!.end.day)
            .add(const Duration(days: 1))
            .millisecondsSinceEpoch - 1;
        if (r.timestamp < start || r.timestamp > end) return false;
      }

      return true;
    }).toList();
  }

  Widget _buildTable(
    String category,
    List<AnalyticsRecord> allLogs,
    PersonnelProvider personnel,
    OrdersProvider orders,
  ) {
    final logs = _filterLogs(category, allLogs);
    if (logs.isEmpty) {
      return const Center(child: Text('Записей нет'));
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: SingleChildScrollView(
        scrollDirection: Axis.vertical,
        child: DataTable(
          columns: const [
            DataColumn(label: Text('Сотрудник')),
            DataColumn(label: Text('Заказ')),
            DataColumn(label: Text('Этап')),
            DataColumn(label: Text('Действие')),
            DataColumn(label: Text('Детали')),
            DataColumn(label: Text('Время')),
          ],
          rows: logs.map((r) {
            return DataRow(
              color: warehouseRowHoverColor,
              cells: [
                DataCell(Text(_employeeNames(personnel, r.userId))),
                DataCell(Text(_orderName(orders, r.orderId))),
                DataCell(Text(_stageName(personnel, r.stageId))),
                DataCell(Text(_localizeAction(r.action))),
                DataCell(Text(r.details)),
                DataCell(Text(_fmtTs(r.timestamp))),
              ],
            );
          }).toList(),
        ),
      ),
    );
  }

  Widget _buildFilters(PersonnelProvider personnel) {
    final employees = personnel.employees;
    return Padding(
      padding: const EdgeInsets.all(8.0),
      child: Wrap(
        spacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          DropdownButton<String?>(
            hint: const Text('Сотрудник'),
            value: _employeeId,
            items: [
              const DropdownMenuItem<String?>(value: null, child: Text('Все')),
              ...employees.map(
                (e) => DropdownMenuItem<String?>(
                  value: e.id,
                  child: Text('${e.lastName} ${e.firstName}'.trim()),
                ),
              ),
            ],
            onChanged: (val) => setState(() => _employeeId = val),
          ),
          TextButton(
            onPressed: () async {
              final now = DateTime.now();
              final picked = await showDateRangePicker(
                context: context,
                firstDate: DateTime(now.year - 5),
                lastDate: DateTime(now.year + 1),
                initialDateRange: _range,
              );
              if (picked != null) {
                setState(() => _range = picked);
              }
            },
            child: Text(
              _range == null
                  ? 'Период'
                  : '${DateFormat('dd.MM.yyyy').format(_range!.start)} - '
                    '${DateFormat('dd.MM.yyyy').format(_range!.end)}',
            ),
          ),
          if (_employeeId != null || _range != null)
            TextButton(
              onPressed: () => setState(() {
                _employeeId = null;
                _range = null;
              }),
              child: const Text('Сброс'),
            ),
        ],
      ),
    );
  }

  // ====== build ======

  @override
  Widget build(BuildContext context) {
    final analytics = context.watch<AnalyticsProvider>();
    final personnel = context.watch<PersonnelProvider>();
    final orders = context.watch<OrdersProvider>();

    return DefaultTabController(
      length: 3,
      child: Builder(
        builder: (context) {
          final TabController controller = DefaultTabController.of(context)!;
          return Scaffold(
            appBar: AppBar(
              leading: const BackButton(),
              title: const Text('Аналитика'),
              bottom: const TabBar(
                tabs: [
                  Tab(text: 'Производство'),
                  Tab(text: 'Менеджеры'),
                  Tab(text: 'Склад'),
                ],
              ),
            ),
            body: Column(
              children: [
                AnimatedBuilder(
                  animation: controller,
                  builder: (context, _) {
                    if (controller.index == 2) {
                      return const SizedBox.shrink();
                    }
                    return _buildFilters(personnel);
                  },
                ),
                Expanded(
                  child: TabBarView(
                    children: [
                      _buildTable('production', analytics.logs, personnel, orders),
                      _buildTable('manager', analytics.logs, personnel, orders),
                      const WarehouseAnalyticsTab(),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
