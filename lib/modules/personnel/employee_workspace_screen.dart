import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../analytics/analytics_routes.dart';
import '../chat/chat_tab.dart';
import '../tasks/tasks_screen.dart';
import '../tasks/workspace_design.dart';
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
  State<EmployeeWorkspaceScreen> createState() =>
      _EmployeeWorkspaceScreenState();
}

class _EmployeeWorkspaceScreenState extends State<EmployeeWorkspaceScreen>
    with TickerProviderStateMixin {
  late List<String> _employeeIds;
  late TabController _employeeTabController;

  @override
  void initState() {
    super.initState();
    _employeeIds = [widget.employeeId];
    _employeeTabController =
        TabController(length: _employeeIds.length, vsync: this);
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
        _employeeTabController =
            TabController(length: _employeeIds.length, vsync: this);
        // Переключаемся на новую вкладку
        _employeeTabController.index = _employeeIds.length - 1;
      });
    }
  }

  String _employeeTabLabel(PersonnelProvider personnel, String id) {
    final emp = personnel.employees.firstWhere(
      (employee) => employee.id == id,
      orElse: () => EmployeeModel(
        id: '',
        lastName: 'Неизвестно',
        firstName: '',
        patronymic: '',
        iin: '',
        positionIds: const [],
      ),
    );
    final firstInitial = emp.firstName.isEmpty ? '' : '${emp.firstName[0]}.';
    return '${emp.lastName} $firstInitial'.trim();
  }

  Future<void> _logoutActiveEmployee() async {
    if (_employeeIds.isEmpty) return;
    final tabIndex = _employeeTabController.index.clamp(
      0,
      _employeeIds.length - 1,
    );
    final analytics = AuditLogService();
    final userId = _employeeIds[tabIndex];
    await analytics.logEvent(
      userId: userId,
      action: 'logout',
      category: 'production',
    );
    if (!mounted) return;

    if (_employeeIds.length > 1) {
      final oldController = _employeeTabController;
      setState(() {
        _employeeIds.removeAt(tabIndex);
        _employeeTabController = TabController(
          length: _employeeIds.length,
          vsync: this,
          initialIndex: tabIndex > 0 ? tabIndex - 1 : 0,
        );
      });
      oldController.dispose();
      return;
    }

    ErrorLogUploader.instance.flush(reason: 'logout');
    AuthHelper.clear();
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const LoginScreen()),
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final personnel = context.watch<PersonnelProvider>();
    final isNarrow = MediaQuery.sizeOf(context).width < 640;

    return Scaffold(
      backgroundColor: WorkspaceColors.background,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(
                isNarrow ? 12 : 20,
                12,
                isNarrow ? 12 : 20,
                4,
              ),
              child: SizedBox(
                height: WorkspaceMetrics.headerActionSize,
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final centerInset = isNarrow ? 118.0 : 250.0;
                    return Stack(
                      alignment: Alignment.center,
                      children: [
                        Align(
                          alignment: Alignment.centerLeft,
                          child: SizedBox(
                            width: isNarrow ? 150 : 280,
                            child: const Padding(
                              padding: EdgeInsets.symmetric(vertical: 10),
                              child: Text(
                                'Рабочее пространство',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: WorkspaceColors.foreground,
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                        ),
                        if (_employeeIds.length > 1)
                          Positioned(
                            left: centerInset,
                            right: centerInset,
                            child: Center(
                              child: ConstrainedBox(
                                constraints:
                                    const BoxConstraints(maxWidth: 440),
                                child: Container(
                                  height: 38,
                                  decoration:
                                      workspaceCardDecoration(radius: 12),
                                  clipBehavior: Clip.antiAlias,
                                  child: TabBar(
                                    controller: _employeeTabController,
                                    isScrollable: true,
                                    dividerHeight: 0,
                                    indicatorSize: TabBarIndicatorSize.tab,
                                    indicator: BoxDecoration(
                                      color: WorkspaceColors.primary
                                          .withValues(alpha: 0.1),
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                    labelColor: WorkspaceColors.primary,
                                    unselectedLabelColor:
                                        WorkspaceColors.mutedForeground,
                                    labelStyle: const TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                    ),
                                    tabs: [
                                      for (final id in _employeeIds)
                                        Tab(
                                          height: 36,
                                          text: _employeeTabLabel(
                                            personnel,
                                            id,
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        Align(
                          alignment: Alignment.centerRight,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              WorkspaceHeaderAction(
                                icon: Icons.add,
                                tooltip: 'Добавить сотрудника',
                                onPressed: _addEmployeeTab,
                              ),
                              const SizedBox(width: 10),
                              WorkspaceHeaderAction(
                                icon: Icons.logout,
                                tooltip: 'Выйти',
                                onPressed: _logoutActiveEmployee,
                              ),
                            ],
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
            Expanded(
              child: TabBarView(
                controller: _employeeTabController,
                children: [
                  for (final id in _employeeIds)
                    _EmployeeWorkspaceTab(employeeId: id),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Один рабочий таб сотрудника: список, активное задание и чат.
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
      length: 3,
      child: ColoredBox(
        color: WorkspaceColors.background,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Container(
                      height: 28,
                      decoration: workspaceCardDecoration(radius: 10),
                      clipBehavior: Clip.antiAlias,
                      child: TabBar(
                        indicatorSize: TabBarIndicatorSize.tab,
                        dividerHeight: 0,
                        indicator: const BoxDecoration(
                          color: WorkspaceColors.primary,
                        ),
                        labelColor: Colors.white,
                        unselectedLabelColor: WorkspaceColors.mutedForeground,
                        labelStyle: const TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                        ),
                        unselectedLabelStyle: const TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w500,
                        ),
                        tabs: const [
                          Tab(height: 28, text: 'Список заданий'),
                          Tab(height: 28, text: 'Задание'),
                          Tab(height: 28, text: 'Чат'),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Tooltip(
                    message: 'Аналитика сотрудника',
                    child: Material(
                      color: WorkspaceColors.setupBackground,
                      borderRadius: BorderRadius.circular(10),
                      child: InkWell(
                        onTap: () => Navigator.of(context).push(
                          AnalyticsRoutes.buildSelfViewRoute(
                            employeeId: employeeId,
                          ),
                        ),
                        borderRadius: BorderRadius.circular(10),
                        hoverColor:
                            WorkspaceColors.primary.withValues(alpha: 0.08),
                        focusColor:
                            WorkspaceColors.primary.withValues(alpha: 0.10),
                        child: Container(
                          height: 28,
                          padding: EdgeInsets.symmetric(
                            horizontal:
                                MediaQuery.sizeOf(context).width < 700 ? 9 : 12,
                          ),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: WorkspaceColors.primary
                                  .withValues(alpha: 0.22),
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.analytics_outlined,
                                size: 16,
                                color: WorkspaceColors.primary,
                              ),
                              if (MediaQuery.sizeOf(context).width >= 700) ...[
                                const SizedBox(width: 6),
                                const Text(
                                  'Аналитика',
                                  style: TextStyle(
                                    color: WorkspaceColors.primary,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: TabBarView(
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
                    workspaceStyle: true,
                  ),
                ],
              ),
            ),
          ],
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
