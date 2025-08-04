import 'package:flutter/material.dart';
import '../chat/chat_tab.dart';
import '../tasks/tasks_screen.dart';

class EmployeeWorkspaceScreen extends StatelessWidget {
  final String employeeId;
  const EmployeeWorkspaceScreen({super.key, required this.employeeId});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Рабочее пространство'),
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Задания'),
              Tab(text: 'Чат'),
            ],
          ),
        ),
        body: const TabBarView(
          children: [
            TasksScreen(),
            ChatTab(),
          ],
        ),
      ),
    );
  }
}
