import 'package:flutter/material.dart';
import 'modules/chat/chat_screen.dart';
import 'modules/production_planning/production_planning_screen.dart';
import 'modules/orders/orders_screen.dart';
import 'modules/personnel/personnel_screen.dart';
import 'modules/production/production_screen.dart';
import 'modules/warehouse/warehouse_screen.dart';

class AdminPanelScreen extends StatelessWidget {
  const AdminPanelScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final modules = [
      {'label': '📦\nСклад', 'page': const WarehouseDashboard()},
      {'label': '👥\nПерсонал', 'page': const PersonnelScreen()},
      {'label': '🧾\nЗаказы', 'page': const OrdersScreen()},
      {'label': '🗓️\nПланир.', 'page': const ProductionPlanningScreen()},
      {'label': '🏭\nПроизв.', 'page': const ProductionScreen()},
      {'label': '💬\nЧат', 'page': const ChatScreen()},
    ];

    return Scaffold(
      appBar: AppBar(title: const Text('Панель администратора')),
      body: Padding(
        padding: const EdgeInsets.all(8.0),
        child: GridView.count(
          crossAxisCount: 5, // 5 модулей в ряд
          crossAxisSpacing: 8,
          mainAxisSpacing: 8,
          childAspectRatio: 1,
          children: modules.map((module) {
            return _buildModuleCard(
              context,
              label: module['label'] as String,
              page: module['page'] as Widget,
            );
          }).toList(),
        ),
      ),
    );
  }

  Widget _buildModuleCard(BuildContext context, {required String label, required Widget page}) {
    return GestureDetector(
      onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => page)),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.lightBlue.shade50,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.blueGrey.shade100),
        ),
        padding: const EdgeInsets.all(4),
        child: Center(
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              height: 1.3,
            ),
          ),
        ),
      ),
    );
  }
}
