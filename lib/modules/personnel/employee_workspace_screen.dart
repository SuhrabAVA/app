import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../chat/chat_tab.dart';
import '../tasks/tasks_screen.dart';
import '../personnel/employee_model.dart';
import '../personnel/personnel_provider.dart';

/// Рабочее пространство сотрудника.
///
/// Экран поддерживает одновременную работу нескольких сотрудников в рамках
/// одного устройства. В верхней части отображается горизонтальный набор
/// вкладок, каждая из которых соответствует конкретному сотруднику. Вкладка
/// содержит две субвкладки: «Задания» и «Чат». При нажатии на кнопку «+»
/// пользователь может выбрать другого сотрудника, и для него откроется
/// отдельная вкладка. Такая структура напоминает поведение вкладок в
/// веб‑браузере и позволяет быстро переключаться между рабочими
/// пространствами разных сотрудников.
class EmployeeWorkspaceScreen extends StatefulWidget {
  final String employeeId;
  const EmployeeWorkspaceScreen({super.key, required this.employeeId});

  @override
  State<EmployeeWorkspaceScreen> createState() => _EmployeeWorkspaceScreenState();
}

class _EmployeeWorkspaceScreenState extends State<EmployeeWorkspaceScreen> with TickerProviderStateMixin {
  late List<String> _employeeIds;
  late TabController _employeeTabController;

  @override
  void initState() {
    super.initState();
    _employeeIds = [widget.employeeId];
    _employeeTabController = TabController(length: _employeeIds.length, vsync: this);
  }

  @override
  void dispose() {
    _employeeTabController.dispose();
    super.dispose();
  }

  /// Открывает диалог для выбора ещё одного сотрудника и добавляет его во
  /// вкладки. Исключает сотрудников, уже открытые в текущем списке.
  Future<void> _addEmployeeTab() async {
    final personnel = context.read<PersonnelProvider>();
    // Список доступных для выбора сотрудников (не включаем уже открытые)
    final available = personnel.employees.where((e) => !_employeeIds.contains(e.id)).toList();
    if (available.isEmpty) {
      // Все сотрудники уже открыты
      return;
    }
    String? selectedId;
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Добавить сотрудника'),
        content: DropdownButtonFormField<String>(
          items: [
            for (final e in available)
              DropdownMenuItem(value: e.id, child: Text('${e.lastName} ${e.firstName}')),
          ],
          onChanged: (val) => selectedId = val,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Отмена'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Добавить'),
          ),
        ],
      ),
    );
    if (selectedId != null && !_employeeIds.contains(selectedId)) {
      setState(() {
        _employeeIds.add(selectedId!);
        // Пересоздаём контроллер вкладок для новой длины.
        _employeeTabController.dispose();
        _employeeTabController = TabController(length: _employeeIds.length, vsync: this);
        // Переключаемся на новую вкладку
        _employeeTabController.index = _employeeIds.length - 1;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final personnel = context.watch<PersonnelProvider>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Рабочее пространство'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: 'Добавить сотрудника',
            onPressed: _addEmployeeTab,
          ),
        ],
        bottom: TabBar(
          controller: _employeeTabController,
          isScrollable: true,
          tabs: [
            for (final id in _employeeIds)
              Tab(
                text: () {
                  final emp = personnel.employees.firstWhere(
                    (e) => e.id == id,
                    orElse: () => EmployeeModel(
                      id: '',
                      lastName: 'Неизвестно',
                      firstName: '',
                      patronymic: '',
                      iin: '',
                      positionIds: [],
                    ),
                  );
                  return '${emp.lastName} ${emp.firstName.isNotEmpty ? emp.firstName[0] + '.' : ''}';
                }(),
              ),
          ],
        ),
      ),
      body: TabBarView(
        controller: _employeeTabController,
        children: [
          for (final id in _employeeIds)
            _EmployeeWorkspaceTab(employeeId: id),
        ],
      ),
    );
  }
}

/// Один рабочий таб сотрудника, содержащий две вкладки: задания и чат.
class _EmployeeWorkspaceTab extends StatelessWidget {
  final String employeeId;
  const _EmployeeWorkspaceTab({required this.employeeId});

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
        appBar: PreferredSize(
          preferredSize: const Size.fromHeight(50),
          child: Container(
            color: Colors.white,
            child: const TabBar(
              tabs: [
                Tab(text: 'Задания'),
                Tab(text: 'Чат'),
              ],
            ),
          ),
        ),
        body: TabBarView(
          children: [
            TasksScreen(employeeId: employeeId),
            ChatTab(
              currentUserId: employeeId,
              currentUserName: fio.isEmpty ? 'Сотрудник' : fio,
            ),
          ],
        ),
      ),
    );
  }
}