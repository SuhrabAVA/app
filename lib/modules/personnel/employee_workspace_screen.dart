import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../chat/chat_tab.dart';
import '../tasks/tasks_screen.dart';
import '../personnel/employee_model.dart';
import '../personnel/personnel_provider.dart';

// Для выхода и возврата на экран входа
import '../../utils/auth_helper.dart';
import '../../login_screen.dart';
import '../analytics/analytics_provider.dart';
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
    final available = personnel.employees
        .where((e) => !e.isFired && !_employeeIds.contains(e.id))
        .toList();
    if (available.isEmpty) {
      // Все сотрудники уже открыты
      return;
    }
    String? selectedId;
    String searchQuery = '';
    String password = '';
    bool wrongPass = false;
    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setStateDialog) {
            final query = searchQuery.trim().toLowerCase();
            final filtered = available.where((emp) {
              if (query.isEmpty) return true;
              final fullName =
                  '${emp.lastName} ${emp.firstName} ${emp.patronymic}'.toLowerCase();
              final login = emp.login.toLowerCase();
              return fullName.contains(query) || login.contains(query);
            }).toList();
            final currentValue =
                filtered.any((e) => e.id == selectedId) ? selectedId : null;
            return AlertDialog(
              title: const Text('Добавить сотрудника'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    decoration: const InputDecoration(
                      labelText: 'Поиск сотрудника',
                      prefixIcon: Icon(Icons.search),
                    ),
                    onChanged: (value) {
                      setStateDialog(() {
                        searchQuery = value;
                        selectedId = null;
                        wrongPass = false;
                      });
                    },
                  ),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<String>(
                    value: currentValue,
                    decoration: const InputDecoration(labelText: 'Сотрудник'),
                    items: [
                      for (final e in filtered)
                        DropdownMenuItem(
                          value: e.id,
                          child: Text(
                            () {
                              final joined = [e.lastName, e.firstName, e.patronymic]
                                  .where((part) => part.trim().isNotEmpty)
                                  .join(' ')
                                  .trim();
                              if (joined.isNotEmpty) return joined;
                              if (e.login.isNotEmpty) return e.login;
                              return 'Без имени';
                            }(),
                          ),
                        ),
                    ],
                    onChanged: filtered.isEmpty
                        ? null
                        : (val) {
                            setStateDialog(() {
                              selectedId = val;
                              wrongPass = false;
                            });
                          },
                  ),
                  if (filtered.isEmpty)
                    const Padding(
                      padding: EdgeInsets.only(top: 8.0),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          'Совпадения не найдены',
                          style: TextStyle(fontSize: 12, color: Colors.grey),
                        ),
                      ),
                    ),
                  const SizedBox(height: 8),
                  TextField(
                    obscureText: true,
                    decoration: InputDecoration(
                      labelText: 'Пароль',
                      errorText: wrongPass ? 'Неверный пароль' : null,
                    ),
                    onChanged: (val) {
                      password = val;
                    },
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Отмена'),
                ),
                TextButton(
                  onPressed: () {
                    if (selectedId == null) {
                      return;
                    }
                    final emp = personnel.employees.firstWhere(
                      (e) => e.id == selectedId,
                      orElse: () => EmployeeModel(
                        id: '',
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
                    if (emp.password == password) {
                      Navigator.pop(ctx);
                    } else {
                      setStateDialog(() {
                        wrongPass = true;
                      });
                    }
                  },
                  child: const Text('Добавить'),
                ),
              ],
            );
          },
        );
      },
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
    final media = MediaQuery.of(context);
    final bool isTablet = media.size.shortestSide >= 600 && media.size.shortestSide < 1100;
    final bool isCompactTablet = isTablet && media.size.shortestSide <= 850;
    final double toolbarHeight = isCompactTablet ? 40 : (isTablet ? 46 : 50);
    final double actionIconSize = isCompactTablet ? 18 : (isTablet ? 20 : 22);
    final double tabLabelSize = isCompactTablet ? 10 : (isTablet ? 12 : 13);
    final EdgeInsetsGeometry tabPadding = isTablet
        ? const EdgeInsets.symmetric(horizontal: 8, vertical: 2)
        : const EdgeInsets.symmetric(horizontal: 12, vertical: 4);

    final theme = Theme.of(context);
    final TextStyle? tabLabelStyle = theme.textTheme.labelLarge?.copyWith(
      fontSize: tabLabelSize,
      fontWeight: FontWeight.w600,
    );
    final TextStyle? tabUnselectedStyle = theme.textTheme.labelMedium?.copyWith(
      fontSize: tabLabelSize,
      fontWeight: FontWeight.w500,
    );

    final scaffold = Scaffold(
      appBar: AppBar(
          toolbarHeight: toolbarHeight,
          titleTextStyle: theme.textTheme.titleMedium?.copyWith(
            fontSize: isTablet ? tabLabelSize + 2 : null,
            fontWeight: FontWeight.w600,
        ),
        title: const Text('Рабочее пространство'),
        actions: [
          // Кнопка добавления сотрудника
          IconButton(
            iconSize: actionIconSize,
            icon: const Icon(Icons.add),
            tooltip: 'Добавить сотрудника',
            onPressed: _addEmployeeTab,
          ),
          // Кнопка выхода из рабочего места сотрудника
          IconButton(
            iconSize: actionIconSize,
            icon: const Icon(Icons.logout),
            tooltip: 'Выйти',
            onPressed: () async {
              final tabIndex = _employeeTabController.index;
              final analytics = context.read<AnalyticsProvider>();
              final userId = _employeeIds[tabIndex];
              await analytics.logEvent(
                orderId: '',
                stageId: '',
                userId: userId,
                action: 'logout',
                category: 'production',
              );
              if (_employeeIds.length > 1) {
                // Если открыто несколько вкладок, закрываем текущую вкладку
                final oldController = _employeeTabController;
                setState(() {
                  _employeeIds.removeAt(tabIndex);
                  // Пересоздаём TabController для нового списка сотрудников
                  _employeeTabController =
                      TabController(length: _employeeIds.length, vsync: this);
                  // Выставляем индекс на предыдущую вкладку, если она есть
                  if (tabIndex > 0) {
                    _employeeTabController.index = tabIndex - 1;
                  }
                });
                oldController.dispose();
              } else {
                // Если это последняя вкладка, выходим на экран входа
                AuthHelper.clear();
                if (!mounted) return;
                Navigator.of(context).pushAndRemoveUntil(
                  MaterialPageRoute(builder: (_) => const LoginScreen()),
                  (route) => false,
                );
              }
            },
          ),
        ],
        bottom: TabBar(
          controller: _employeeTabController,
          isScrollable: true,
          labelPadding: isTablet ? tabPadding : null,
          labelStyle: tabLabelStyle,
          unselectedLabelStyle: tabUnselectedStyle,
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

    if (!isTablet) {
      return scaffold;
    }

    return Theme(
      data: theme.copyWith(
        tabBarTheme: theme.tabBarTheme.copyWith(
          labelPadding: tabPadding,
          labelStyle: tabLabelStyle,
          unselectedLabelStyle: tabUnselectedStyle,
        ),
        iconTheme: theme.iconTheme.copyWith(size: actionIconSize),
        appBarTheme: theme.appBarTheme.copyWith(toolbarHeight: toolbarHeight),
      ),
      child: scaffold,
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

    final media = MediaQuery.of(context);
    final bool isTablet = media.size.shortestSide >= 600 && media.size.shortestSide < 1100;
    final bool isCompactTablet = isTablet && media.size.shortestSide <= 850;
    final double targetTextScale = math.max(
      media.textScaleFactor,
      isCompactTablet
          ? 1.12
          : (isTablet
              ? 1.08
              : 1.0),
    );
    final mediaData = media.copyWith(textScaleFactor: targetTextScale);
    final theme = Theme.of(context);
    final TextStyle? baseTabLabel = theme.tabBarTheme.labelStyle ?? theme.textTheme.labelLarge;
    final TextStyle? baseTabUnselected = theme.tabBarTheme.unselectedLabelStyle ?? theme.textTheme.labelMedium;
    final ThemeData compactTheme = theme.copyWith(
      visualDensity: isCompactTablet
          ? const VisualDensity(horizontal: 0.5, vertical: 0.5)
          : (isTablet
              ? const VisualDensity(horizontal: 0.25, vertical: 0.25)
              : theme.visualDensity),
      tabBarTheme: theme.tabBarTheme.copyWith(
        labelPadding: isTablet
            ? const EdgeInsets.symmetric(horizontal: 8)
            : theme.tabBarTheme.labelPadding,
        labelStyle: baseTabLabel?.copyWith(
          fontSize: isCompactTablet ? 13 : (isTablet ? 14 : baseTabLabel?.fontSize),
        ),
        unselectedLabelStyle: baseTabUnselected?.copyWith(
          fontSize: isCompactTablet ? 13 : (isTablet ? 14 : baseTabUnselected?.fontSize),
        ),
      ),
      iconTheme: theme.iconTheme.copyWith(
        size: isCompactTablet ? 22 : (isTablet ? 24 : theme.iconTheme.size),
      ),
      appBarTheme: theme.appBarTheme.copyWith(
        toolbarHeight: isCompactTablet ? 52 : (isTablet ? 56 : theme.appBarTheme.toolbarHeight),
      ),
    );
    final double tabBarHeight = isCompactTablet ? 34 : (isTablet ? 36 : 38);

    return MediaQuery(
      data: mediaData,
      child: Theme(
        data: compactTheme,
        child: DefaultTabController(
          length: 3,
          child: Scaffold(
            appBar: PreferredSize(
              preferredSize: Size.fromHeight(tabBarHeight),
              child: Container(
                color: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: TabBar(
                  indicatorSize: TabBarIndicatorSize.label,
                  labelPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
                  indicatorPadding: EdgeInsets.zero,
                  labelStyle: Theme.of(context)
                      .textTheme
                      .labelLarge
                      ?.copyWith(fontSize: isCompactTablet ? 11 : 12, fontWeight: FontWeight.w600),
                  unselectedLabelStyle: Theme.of(context)
                      .textTheme
                      .labelMedium
                      ?.copyWith(fontSize: isCompactTablet ? 10 : 11, fontWeight: FontWeight.w500),
                  tabs: const [
                    Tab(text: 'Список заданий'),
                    Tab(text: 'Задание'),
                    Tab(text: 'Чат'),
                  ],
                ),
              ),
            ),
            body: TabBarView(
              children: [
                TasksScreen(
                  employeeId: employeeId,
                  showListOnly: true,
                  compactList: true,
                ),
                TasksScreen(
                  employeeId: employeeId,
                  hideListPanel: true,
                ),
                ChatTab(
                  currentUserId: employeeId,
                  currentUserName: fio.isEmpty ? 'Сотрудник' : fio,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}