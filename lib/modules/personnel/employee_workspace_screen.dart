import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../analytics/analytics_routes.dart';
import '../chat/chat_tab.dart';
import '../tasks/tasks_screen.dart';
import '../personnel/employee_model.dart';
import '../personnel/personnel_provider.dart';
import '../personnel/position_model.dart';

// Для выхода и возврата на экран входа
import '../../services/error_log_uploader.dart';
import '../../utils/auth_helper.dart';
import '../../login_screen.dart';
import '../../services/audit_log_service.dart';
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

  /// Открывает выбор ещё одного сотрудника и добавляет его во вкладки.
  /// Исключает сотрудников, уже открытых в текущем списке.
  ///
  /// Список устроен как на экране входа: поиск по имени и должности, карточки
  /// с фото, ФИО и должностью; пароль спрашивается после выбора человека.
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
    final String? selectedId = await showDialog<String>(
      context: context,
      builder: (ctx) => _AddEmployeeDialog(
        available: available,
        personnel: personnel,
      ),
    );
    if (selectedId != null && !_employeeIds.contains(selectedId)) {
      setState(() {
        _employeeIds.add(selectedId);
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
    final bool isTablet1280x800 = isTablet &&
        ((media.size.width == 1280 && media.size.height == 800) ||
            (media.size.width == 800 && media.size.height == 1280));
    final bool isTablet1000x700 = isTablet &&
        ((media.size.width == 1000 && media.size.height == 700) ||
            (media.size.width == 700 && media.size.height == 1000));
    const double topBlockScale = 0.6;
    final double toolbarHeight = isTablet
        ? ((isTablet1280x800
                ? 20
                : (isTablet1000x700 ? 19 : (isCompactTablet ? 24 : 28))) *
            topBlockScale)
        : 50 * topBlockScale;
    final double actionIconSize = isTablet
        ? ((isTablet1280x800
                ? 11
                : (isTablet1000x700 ? 10 : (isCompactTablet ? 14 : 16))) *
            0.8)
        : 22 * 0.8;
    final double tabLabelSize = isTablet1280x800
        ? 7
        : (isTablet1000x700
            ? 6.8
            : (isCompactTablet ? 8 : (isTablet ? 9.5 : 13 * topBlockScale)));
    final EdgeInsetsGeometry tabPadding = isTablet
        ? EdgeInsets.symmetric(
            horizontal: isTablet1280x800
                ? 6
                : (isTablet1000x700 ? 5 : 8),
            vertical: isTablet1280x800
                ? 1
                : (isTablet1000x700 ? 0.5 : 2),
          )
        : const EdgeInsets.symmetric(horizontal: 8, vertical: 2);

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
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFFE1E1E8)),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x08000000),
                    blurRadius: 6,
                    offset: Offset(0, 2),
                  ),
                ],
              ),
              child: IconButton(
                padding: EdgeInsets.zero,
                constraints: BoxConstraints.tightFor(
                  width: isTablet ? 26 : 24,
                  height: isTablet ? 26 : 24,
                ),
                iconSize: actionIconSize,
                icon: const Icon(Icons.add),
                tooltip: 'Добавить сотрудника',
                onPressed: _addEmployeeTab,
              ),
            ),
          ),
          // Кнопка выхода из рабочего места сотрудника
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFFE1E1E8)),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x08000000),
                    blurRadius: 6,
                    offset: Offset(0, 2),
                  ),
                ],
              ),
              child: IconButton(
                padding: EdgeInsets.zero,
                constraints: BoxConstraints.tightFor(
                  width: isTablet ? 26 : 24,
                  height: isTablet ? 26 : 24,
                ),
                iconSize: actionIconSize,
                icon: const Icon(Icons.logout),
                tooltip: 'Выйти',
                onPressed: () async {
                  final tabIndex = _employeeTabController.index;
                  final analytics = AuditLogService();
                  final userId = _employeeIds[tabIndex];
                  await analytics.logEvent(
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
                    // Если это последняя вкладка, выходим на экран входа.
                    // Журнал ошибок выгружаем ДО очистки данных сотрудника —
                    // иначе записи уедут без имени и id.
                    ErrorLogUploader.instance.flush(reason: 'logout');
                    AuthHelper.clear();
                    if (!mounted) return;
                    Navigator.of(context).pushAndRemoveUntil(
                      MaterialPageRoute(builder: (_) => const LoginScreen()),
                      (route) => false,
                    );
                  }
                },
              ),
            ),
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
                height: isTablet ? 28 : 18,
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
    final bool isTablet1280x800 = isTablet &&
        ((media.size.width == 1280 && media.size.height == 800) ||
            (media.size.width == 800 && media.size.height == 1280));
    final bool isTablet1000x700 = isTablet &&
        ((media.size.width == 1000 && media.size.height == 700) ||
            (media.size.width == 700 && media.size.height == 1000));
    final double targetTextScale = math.max(
      media.textScaleFactor,
      isTablet1280x800
          ? 1.0
          : (isTablet1000x700
              ? 0.98
              : (isCompactTablet
                  ? 1.12
                  : (isTablet
                      ? 1.08
                      : 1.0))),
    );
    final mediaData = media.copyWith(textScaleFactor: targetTextScale);
    final theme = Theme.of(context);
    final TextStyle? baseTabLabel = theme.tabBarTheme.labelStyle ?? theme.textTheme.labelLarge;
    final TextStyle? baseTabUnselected = theme.tabBarTheme.unselectedLabelStyle ?? theme.textTheme.labelMedium;
    final ThemeData compactTheme = theme.copyWith(
      visualDensity: isTablet1280x800
          ? const VisualDensity(horizontal: -0.2, vertical: -0.2)
          : (isTablet1000x700
              ? const VisualDensity(horizontal: -0.4, vertical: -0.4)
              : (isCompactTablet
                  ? const VisualDensity(horizontal: 0.5, vertical: 0.5)
                  : (isTablet
                      ? const VisualDensity(horizontal: 0.25, vertical: 0.25)
                      : theme.visualDensity))),
      tabBarTheme: theme.tabBarTheme.copyWith(
        labelPadding: isTablet
            ? EdgeInsets.symmetric(horizontal: isTablet1000x700 ? 6 : 8)
            : theme.tabBarTheme.labelPadding,
        labelStyle: baseTabLabel?.copyWith(
          fontSize: isTablet1280x800
              ? 12
              : (isTablet1000x700
                  ? 11
                  : (isCompactTablet ? 13 : (isTablet ? 14 : baseTabLabel?.fontSize))),
        ),
        unselectedLabelStyle: baseTabUnselected?.copyWith(
          fontSize: isTablet1280x800
              ? 12
              : (isTablet1000x700
                  ? 11
                  : (isCompactTablet ? 13 : (isTablet ? 14 : baseTabUnselected?.fontSize))),
        ),
      ),
      iconTheme: theme.iconTheme.copyWith(
        size: isTablet1280x800
            ? 20
            : (isTablet1000x700
                ? 18
                : (isCompactTablet ? 22 : (isTablet ? 24 : theme.iconTheme.size))),
      ),
      appBarTheme: theme.appBarTheme.copyWith(
        toolbarHeight: isTablet1280x800
            ? 48
            : (isTablet1000x700
                ? 44
                : (isCompactTablet ? 52 : (isTablet ? 56 : theme.appBarTheme.toolbarHeight))),
      ),
    );
    final double tabBarHeight = isTablet1280x800
        ? 18
        : (isTablet1000x700 ? 17 : (isCompactTablet ? 23 : (isTablet ? 25 : 26)));
    const Color tabBackground = Color(0xFFF1F1F5);
    const Color tabBorder = Color(0xFFE1E1E8);

    return MediaQuery(
      data: mediaData,
      child: Theme(
        data: compactTheme,
        child: DefaultTabController(
          length: 3,
          child: Scaffold(
            appBar: PreferredSize(
              preferredSize: Size.fromHeight(tabBarHeight + 6),
              child: Container(
                color: Colors.white,
                padding: const EdgeInsets.fromLTRB(16, 3, 16, 3),
                child: Row(
                  children: [
                    Expanded(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: tabBackground,
                          borderRadius: BorderRadius.circular(18),
                          border: Border.all(color: tabBorder),
                        ),
                        child: TabBar(
                          indicatorSize: TabBarIndicatorSize.tab,
                          indicatorPadding: const EdgeInsets.all(1.2),
                          labelColor: Colors.black,
                          unselectedLabelColor: const Color(0xFF6F6F7B),
                          labelStyle: Theme.of(context)
                              .textTheme
                              .labelLarge
                              ?.copyWith(
                                fontSize: isTablet1280x800
                                    ? 7
                                    : (isTablet1000x700 ? 6.5 : (isCompactTablet ? 8.8 : 9.8)),
                                fontWeight: FontWeight.w600,
                              ),
                          unselectedLabelStyle: Theme.of(context)
                              .textTheme
                              .labelMedium
                              ?.copyWith(
                                fontSize: isTablet1280x800
                                    ? 6.7
                                    : (isTablet1000x700 ? 6.2 : (isCompactTablet ? 8.2 : 9.2)),
                                fontWeight: FontWeight.w500,
                              ),
                          indicator: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(16),
                            boxShadow: const [
                              BoxShadow(
                                color: Color(0x14000000),
                                blurRadius: 6,
                                offset: Offset(0, 2),
                              ),
                            ],
                          ),
                          tabs: const [
                            Tab(text: 'Список заданий'),
                            Tab(text: 'Задание'),
                            Tab(text: 'Чат'),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    // Компактная кнопка «Моя аналитика»: selfView сотрудника
                    // этой вкладки (id подтверждён паролем при входе/добавлении).
                    Tooltip(
                      message: 'Моя аналитика',
                      child: Material(
                        color: tabBackground,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(18),
                          side: const BorderSide(color: tabBorder),
                        ),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(18),
                          onTap: () => Navigator.of(context).push(
                            AnalyticsRoutes.buildSelfViewRoute(
                                employeeId: employeeId),
                          ),
                          child: SizedBox(
                            height: tabBarHeight,
                            width: tabBarHeight + 10,
                            child: Icon(
                              Icons.query_stats,
                              size: (tabBarHeight - 6).clamp(11.0, 18.0),
                              color: const Color(0xFF6F6F7B),
                            ),
                          ),
                        ),
                      ),
                    ),
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

/// Выбор сотрудника для новой вкладки — тот же паттерн, что на экране входа:
/// поиск по имени и должности, карточки с фото, затем ввод пароля.
///
/// Возвращает id сотрудника после успешной проверки пароля, либо null.
class _AddEmployeeDialog extends StatefulWidget {
  const _AddEmployeeDialog({
    required this.available,
    required this.personnel,
  });

  final List<EmployeeModel> available;
  final PersonnelProvider personnel;

  @override
  State<_AddEmployeeDialog> createState() => _AddEmployeeDialogState();
}

class _AddEmployeeDialogState extends State<_AddEmployeeDialog> {
  final TextEditingController _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  String _fullName(EmployeeModel e) {
    final joined = [e.lastName, e.firstName, e.patronymic]
        .where((part) => part.trim().isNotEmpty)
        .join(' ')
        .trim();
    if (joined.isNotEmpty) return joined;
    if (e.login.trim().isNotEmpty) return e.login.trim();
    return 'Без имени';
  }

  String _positionName(EmployeeModel e) {
    if (e.positionIds.isEmpty) return 'Сотрудник';
    final match = widget.personnel.positions.firstWhere(
      (p) => p.id == e.positionIds.first,
      orElse: () => PositionModel(id: '', name: ''),
    );
    return match.name.trim().isEmpty ? 'Сотрудник' : match.name.trim();
  }

  Future<void> _pick(EmployeeModel employee) async {
    final accepted = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _EmployeePasswordDialog(
        title: _fullName(employee),
        password: employee.password,
      ),
    );
    if (accepted == true && mounted) {
      Navigator.of(context).pop(employee.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final query = _query.trim().toLowerCase();
    final filtered = widget.available.where((e) {
      if (query.isEmpty) return true;
      return _fullName(e).toLowerCase().contains(query) ||
          _positionName(e).toLowerCase().contains(query) ||
          e.login.toLowerCase().contains(query);
    }).toList();

    return AlertDialog(
      title: const Text('Добавить сотрудника'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Выберите сотрудника для новой вкладки',
              style: TextStyle(fontSize: 13, color: Colors.grey),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _searchController,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Поиск по имени или должности',
                prefixIcon: Icon(Icons.search),
              ),
              onChanged: (value) => setState(() => _query = value),
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 300,
              child: filtered.isEmpty
                  ? const Center(child: Text('Сотрудники не найдены'))
                  : ListView.separated(
                      itemCount: filtered.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 8),
                      itemBuilder: (context, index) {
                        final employee = filtered[index];
                        final photo = employee.photoUrl;
                        return InkWell(
                          onTap: () => _pick(employee),
                          borderRadius: BorderRadius.circular(8),
                          child: Container(
                            decoration: BoxDecoration(
                              border: Border.all(color: Colors.grey.shade300),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 12,
                            ),
                            child: Row(
                              children: [
                                CircleAvatar(
                                  radius: 20,
                                  backgroundColor: Colors.grey.shade200,
                                  foregroundImage:
                                      (photo != null && photo.isNotEmpty)
                                          ? NetworkImage(photo)
                                          : null,
                                  child: (photo == null || photo.isEmpty)
                                      ? const Icon(Icons.person_outline,
                                          color: Colors.grey)
                                      : null,
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        _fullName(employee),
                                        style: const TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        _positionName(employee),
                                        style: const TextStyle(
                                          fontSize: 12,
                                          color: Colors.grey,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const Icon(Icons.chevron_right,
                                    color: Colors.grey),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Отмена'),
        ),
      ],
    );
  }
}

/// Ввод пароля выбранного сотрудника — как в диалоге входа.
class _EmployeePasswordDialog extends StatefulWidget {
  const _EmployeePasswordDialog({
    required this.title,
    required this.password,
  });

  final String title;
  final String password;

  @override
  State<_EmployeePasswordDialog> createState() =>
      _EmployeePasswordDialogState();
}

class _EmployeePasswordDialogState extends State<_EmployeePasswordDialog> {
  final TextEditingController _controller = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    if (_controller.text.trim() == widget.password) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() => _error = 'Неверный пароль');
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Введите пароль для ${widget.title}'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _controller,
            autofocus: true,
            obscureText: true,
            decoration: const InputDecoration(labelText: 'Пароль'),
            onSubmitted: (_) => _submit(),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(
              _error!,
              style: const TextStyle(color: Colors.red, fontSize: 12),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Отмена'),
        ),
        ElevatedButton(
          onPressed: _submit,
          child: const Text('Добавить'),
        ),
      ],
    );
  }
}
