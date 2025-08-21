import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../personnel/personnel_provider.dart';
import '../personnel/employee_model.dart';
import '../orders/orders_provider.dart';
import '../orders/order_model.dart';
import 'analytics_provider.dart';
import 'analytics_record.dart';

/// Экран отображения аналитических данных. Представляет собой таблицу
/// событий, где фиксируются действия сотрудников по этапам заказов.
/// Каждая строка показывает имя сотрудника, номер заказа, название
/// этапа, тип действия и время выполнения.
class AnalyticsScreen extends StatelessWidget {
  const AnalyticsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final analytics = context.watch<AnalyticsProvider>();
    final personnel = context.watch<PersonnelProvider>();
    final ordersProvider = context.watch<OrdersProvider>();
    final logs = analytics.logs;

    String getEmployeeNames(String userIds) {
      final ids = userIds.split(','); // если у вас список id сохранён как строка
      return ids.map((id) {
        try {
          final EmployeeModel e = personnel.employees.firstWhere((e) => e.id == id);
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
        final stage =
            personnel.workplaces.firstWhere((w) => w.id == id);
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
        default:
          return action;
      }
    }

   return Scaffold(
  appBar: AppBar(
    leading: BackButton(), // ⬅ кнопка "назад"
    title: const Text('Аналитика производства'),
  ),
  body: logs.isEmpty
      ? const Center(child: Text('Записей нет'))
      : SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SingleChildScrollView(
            scrollDirection: Axis.vertical,
            child: DataTable(
              columns: const [
                DataColumn(label: Text('Сотрудник')),
                DataColumn(label: Text('Заказ')),
                DataColumn(label: Text('Этап')),
                DataColumn(label: Text('Действие')),
                DataColumn(label: Text('Время')),
              ],
              rows: logs.map((record) {
                return DataRow(cells: [
                  DataCell(Text(getEmployeeNames(record.userId))),
                  DataCell(Text(getOrderName(record.orderId))),
                  DataCell(Text(getStageName(record.stageId))),
                  DataCell(Text(localizeAction(record.action))),
                  DataCell(Text(formatTimestamp(record.timestamp))),
                ]);
              }).toList(),
            ),
          ),
        ),
);

  }
}