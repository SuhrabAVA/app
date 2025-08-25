import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../personnel/employee_model.dart';
import '../personnel/personnel_provider.dart';
import '../orders/order_model.dart';
import '../orders/orders_provider.dart';

import 'analytics_provider.dart';
import 'analytics_record.dart';

/// Экран отображения аналитики для разных категорий сотрудников.
///
/// Вверху представлены фильтры по сотруднику и диапазону дат,
/// ниже — вкладки для категорий: производство, менеджеры и склад.
/// Каждая вкладка показывает таблицу событий, относящихся к выбранной
/// категории.
class AnalyticsScreen extends StatefulWidget {
  const AnalyticsScreen({super.key});

  @override
  State<AnalyticsScreen> createState() => _AnalyticsScreenState();
}

class _AnalyticsScreenState extends State<AnalyticsScreen> {
  String? _employeeId;
  DateTimeRange? _range;

  @override
  Widget build(BuildContext context) {
    final analytics = context.watch<AnalyticsProvider>();
    final personnel = context.watch<PersonnelProvider>();
    final ordersProvider = context.watch<OrdersProvider>();

    String getEmployeeNames(String userIds) {
      final ids = userIds.split(',');
      return ids.map((id) {
        try {
          final EmployeeModel e =
              personnel.employees.firstWhere((e) => e.id == id);
          return '${e.lastName} ${e.firstName}'.trim();
        } catch (_) {
          return id;
        }
      }).join(', ');
    }

    String getOrderName(String id) {
      try {
        final OrderModel o = ordersProvider.orders.firstWhere((o) => o.id == id);
        final product = o.product.type;
        return product.isNotEmpty ? '${o.id} ($product)' : o.id;
      } catch (_) {
        return id;
      }
    }

    String getStageName(String id) {
      try {
        final stage = personnel.workplaces.firstWhere((w) => w.id == id);
        return stage.name;
      } catch (_) {
        return id;
      }
    }

    String formatTimestamp(int ts) {
      final dt = DateTime.fromMillisecondsSinceEpoch(ts);
      return DateFormat('dd.MM.yyyy HH:mm:ss').format(dt);
    }

    String localizeAction(String action) {
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

    List<AnalyticsRecord> filterLogs(String category) {
      return analytics.logs.where((r) {
        if (r.category != category) return false;
        if (_employeeId != null && _employeeId!.isNotEmpty) {
          final ids = r.userId.split(',');
          if (!ids.contains(_employeeId)) return false;
        }
        if (_range != null) {
          final start = _range!.start.millisecondsSinceEpoch;
          final end = _range!.end
              .add(const Duration(days: 1))
              .millisecondsSinceEpoch;
          if (r.timestamp < start || r.timestamp > end) return false;
        }
        return true;
      }).toList();
    }

    Widget buildTable(String category) {
      final logs = filterLogs(category);
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
            rows: logs.map((record) {
              return DataRow(cells: [
                DataCell(Text(getEmployeeNames(record.userId))),
                DataCell(Text(getOrderName(record.orderId))),
                DataCell(Text(getStageName(record.stageId))),
                DataCell(Text(localizeAction(record.action))),
                DataCell(Text(record.details)),
                DataCell(Text(formatTimestamp(record.timestamp))),
              ]);
            }).toList(),
          ),
        ),
      );
    }

    Widget buildFilters() {
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

    return DefaultTabController(
      length: 3,
      child: Scaffold(
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
            buildFilters(),
            Expanded(
              child: TabBarView(
                children: [
                  buildTable('production'),
                  buildTable('manager'),
                  buildTable('warehouse'),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

