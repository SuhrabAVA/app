import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../orders/orders_screen.dart';
import '../chat/chat_tab.dart';
import '../personnel/personnel_provider.dart';
import '../personnel/employee_model.dart';

class ManagerWorkspaceScreen extends StatelessWidget {
  final String employeeId;
  const ManagerWorkspaceScreen({super.key, required this.employeeId});

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
          title: Text(fio.isEmpty ? 'Менеджер' : '$fio • Менеджер'),
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Заказы', icon: Icon(Icons.assignment)),
              Tab(text: 'Чат', icon: Icon(Icons.chat_bubble_outline)),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            // Полный доступ к заказам
            const OrdersScreen(),
            // Отдельная комната менеджеров
            ChatScreenCompat(
              currentUserId: emp.id,
              currentUserName: fio.isEmpty ? 'Менеджер' : fio,
              roomId: 'managers',   // общий менеджерский чат
              isLead: true,
            ),
          ],
        ),
      ),
    );
  }
}
