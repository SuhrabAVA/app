import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../warehouse/warehouse_screen.dart';
import '../chat/chat_tab.dart';
import '../personnel/personnel_provider.dart';
import '../personnel/employee_model.dart';
import '../analytics/analytics_provider.dart';
import '../../utils/auth_helper.dart';
import '../../login_screen.dart';

class WarehouseManagerWorkspaceScreen extends StatelessWidget {
  final String employeeId;
  const WarehouseManagerWorkspaceScreen({super.key, required this.employeeId});

  @override
  Widget build(BuildContext context) {
    final personnel = context.watch<PersonnelProvider>();
    final EmployeeModel emp = personnel.employees.firstWhere(
      (e) => e.id == employeeId,
      orElse: () => EmployeeModel(
        id: employeeId,
        lastName: '',
        firstName: '',
        patronymic: '',
        iin: '',
        photoUrl: null,
        positionIds: const [],
        isFired: false,
        comments: '',
        login: '',
        password: '',
      ),
    );

    final fio = [emp.lastName, emp.firstName, emp.patronymic]
        .where((s) => s.trim().isNotEmpty)
        .join(' ')
        .trim();

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: Text(
              fio.isEmpty ? 'Заведующий складом' : '$fio • Заведующий складом'),
              actions: [
            IconButton(
              icon: const Icon(Icons.logout),
              tooltip: 'Выйти',
              onPressed: () async {
                final analytics = context.read<AnalyticsProvider>();
                await analytics.logEvent(
                  orderId: '',
                  stageId: '',
                  userId: emp.id,
                  action: 'logout',
                  category: 'warehouse',
                );
                AuthHelper.clear();
                if (!context.mounted) return;
                Navigator.of(context).pushAndRemoveUntil(
                  MaterialPageRoute(builder: (_) => const LoginScreen()),
                  (route) => false,
                );
              },
            ),
          ],
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Склад', icon: Icon(Icons.warehouse)),
              Tab(text: 'Чат', icon: Icon(Icons.chat_bubble_outline)),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            const WarehouseDashboard(),
            ChatTab(
              currentUserId: emp.id,
              currentUserName:
                  fio.isEmpty ? 'Заведующий складом' : fio,
              roomId: 'general',
            ),
          ],
        ),
      ),
    );
  }
}