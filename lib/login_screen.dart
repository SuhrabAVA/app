import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'modules/personnel/employee_model.dart';        // <-- тип EmployeeModel
import 'modules/personnel/personnel_constants.dart';   // <-- kManagerId
import 'modules/personnel/position_model.dart';        // <-- если используешь PositionModel в проверке
import 'modules/manager/manager_workspace_screen.dart';
import 'admin_panel.dart';
import 'modules/personnel/employee_workspace_screen.dart';
import 'modules/personnel/personnel_provider.dart';
import 'utils/auth_helper.dart';
import 'modules/warehouse_manager/warehouse_manager_workspace_screen.dart';
import 'modules/analytics/analytics_provider.dart';

bool isManagerUser(EmployeeModel emp, PersonnelProvider pr) {
  // 1) По id должности
  final ids = emp.positionIds.map((e) => e.toString()).toSet();
  if (ids.contains(kManagerId)) return true;

  // 2) По названию должности "Менеджер" (если id другой)
  final mgr = pr.findManagerPosition();
  if (mgr != null && ids.contains(mgr.id)) return true;

  // 3) По логину (email у модели нет)
  // EmployeeModel.login is non-nullable, so we can safely call toLowerCase directly.
  final loginLower = emp.login.toLowerCase();
  if (loginLower.contains('manager') || loginLower.contains('менедж')) return true;

  return false;
}
bool isWarehouseHeadUser(EmployeeModel emp, PersonnelProvider pr) {
  final ids = emp.positionIds.map((e) => e.toString()).toSet();
  if (ids.contains(kWarehouseHeadId)) return true;

  final wh = pr.findWarehouseHeadPosition();
  if (wh != null && ids.contains(wh.id)) return true;

  // EmployeeModel.login is non-nullable, so we can safely call toLowerCase directly.
  final loginLower = emp.login.toLowerCase();
  if (loginLower.contains('warehouse') || loginLower.contains('склад')) return true;

  return false;
}
/// Главный экран авторизации. Показывает список пользователей, где первым
/// всегда идёт технический лидер, а дальше – сотрудники, добавленные
/// техническим лидером. Пользователь выбирает своё имя, вводит пароль и
/// переходит в соответствующий модуль приложения.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    // After the first frame, ensure mandatory positions exist and load employees.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final pr = context.read<PersonnelProvider>();
      // Guarantee that manager and warehouse head positions exist in the provider.
      await pr.ensureManagerPosition();
      await pr.ensureWarehouseHeadPosition();
      // Fetch employees once to populate the list immediately. The provider also listens to realtime updates.
      await pr.fetchEmployees();
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[100],
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: Card(
            elevation: 4,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            child: Padding(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Вход в систему',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Выберите ваше имя для начала работы',
                    style: TextStyle(fontSize: 14, color: Colors.grey),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _searchController,
                    decoration: const InputDecoration(
                      labelText: 'Поиск по имени или должности',
                      prefixIcon: Icon(Icons.search),
                    ),
                    onChanged: (value) {
                      setState(() {
                        _searchQuery = value;
                      });
                    },
                  ),
                  const SizedBox(height: 16),
                  Consumer<PersonnelProvider>(
                    builder: (context, personnel, _) {
                      // Формируем список пользователей: первый – технический лидер.
                      final List<_UserItem> users = [];
                      users.add(_UserItem(
                        id: 'tech_leader',
                        name: 'Технический лидер',
                        position: 'Технический лидер',
                        password: '123123',
                        isTechLeader: true,
                      ));
                      for (final e in personnel.employees) {
                        if (e.isFired) continue;
                        String positionName = '';
                        if (e.positionIds.isNotEmpty) {
                          final match = personnel.positions
                              .firstWhere(
                                (p) => p.id == e.positionIds.first,
                                orElse: () => PositionModel(id: '', name: ''),
                              )
                              .name;
                          positionName = match;
                        }
                        final fullName =
                            '${e.lastName} ${e.firstName} ${e.patronymic}';
                        users.add(_UserItem(
                          id: e.id,
                          name: fullName,
                          position: positionName,
                          password: e.password,
                          isTechLeader: false,
                        ));
                      }
                      if (personnel.employees.isEmpty) {
                        return const Center(child: CircularProgressIndicator());
                      }

                      final query = _searchQuery.toLowerCase();
                      final filtered = users
                          .where((u) => u.name.toLowerCase().contains(query) ||
                              u.position.toLowerCase().contains(query))
                          .toList();

                      if (filtered.isEmpty) {
                        return const Center(child: Text('Пользователи не найдены'));
                      }

                      return SizedBox(
                        height: 300,
                        child: ListView.separated(
                          itemCount: filtered.length,
                          separatorBuilder: (_, __) => const SizedBox(height: 8),
                          itemBuilder: (context, index) {
                            final user = filtered[index];
                            return InkWell(
                              onTap: () => _promptPassword(context, user),
                              borderRadius: BorderRadius.circular(8),
                              child: Container(
                                decoration: BoxDecoration(
                                  border: Border.all(color: Colors.grey.shade300),
                                  borderRadius: BorderRadius.circular(8),
                                  ),
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 12, vertical: 12),
                                child: Row(
                                  children: [
                                    CircleAvatar(
                                      radius: 20,
                                      backgroundColor: Colors.grey.shade200,
                                      child: const Icon(Icons.person_outline,
                                          color: Colors.grey),
                                    ),
                                     const SizedBox(width: 12),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            user.name,
                                            style: const TextStyle(
                                              fontSize: 16,
                                              fontWeight: FontWeight.w500,
                                            ),
                                          ),
                                          const SizedBox(height: 2),
                                          Text(
                                            user.position,
                                            style: const TextStyle(
                                              fontSize: 12,
                                              color: Colors.grey,
                                           ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  const Icon(Icons.chevron_right, color: Colors.grey),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    );
                  },
                ),
                // ====== /список пользователей ======
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

  /// Показывает диалог ввода пароля и при успешном вводе
  /// выполняет навигацию в нужный модуль.
  Future<void> _promptPassword(BuildContext context, _UserItem user) async {
    final TextEditingController controller = TextEditingController();
    String? error;
    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              title: Text('Введите пароль для ${user.name}'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: controller,
                    obscureText: true,
                    decoration: const InputDecoration(labelText: 'Пароль'),
                  ),
                  if (error != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      error!,
                      style: const TextStyle(color: Colors.red, fontSize: 12),
                    ),
                  ],
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Отмена'),
                ),
                ElevatedButton(
                  onPressed: () async {
                    final password = controller.text.trim();
                    if (password == user.password) {
                      // Запоминаем пользователя в AuthHelper
                      if (user.isTechLeader) {
                        AuthHelper.setTechLeader(name: user.name);
                      } else {
                        AuthHelper.setEmployee(id: user.id, name: user.name);
                      }
                      // логируем вход
                      final analytics = context.read<AnalyticsProvider>();
                      String category;
                      if (user.isTechLeader) {
                        category = 'manager';
                      } else {
                        final pr = context.read<PersonnelProvider>();
                        final emp = pr.employees.firstWhere(
                          (e) => e.id == user.id,
                          orElse: () => EmployeeModel(
                            id: user.id,
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
                        if (isManagerUser(emp, pr)) {
                          category = 'manager';
                        } else if (isWarehouseHeadUser(emp, pr)) {
                          category = 'warehouse';
                        } else {
                          category = 'production';
                        }
                      }
                      await analytics.logEvent(
                        orderId: '',
                        stageId: '',
                        userId: user.id,
                        action: 'login',
                        category: category,
                      );
                      Navigator.pop(ctx);
                      // Навигация
                      if (user.isTechLeader) {
                        Navigator.pushReplacement(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const AdminPanelScreen(),
                          ),
                        );
                      } else {
                        final pr = context.read<PersonnelProvider>();
                        final emp = pr.employees.firstWhere(
                          (e) => e.id == user.id,
                          orElse: () => EmployeeModel(
                            id: user.id,
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

                        final screen = isManagerUser(emp, pr)
                            ? ManagerWorkspaceScreen(employeeId: user.id)
                            : isWarehouseHeadUser(emp, pr)
                                ? WarehouseManagerWorkspaceScreen(employeeId: user.id)
                                : EmployeeWorkspaceScreen(employeeId: user.id);
                        Navigator.pushReplacement(
                          context,
                          MaterialPageRoute(builder: (_) => screen),
                        );
                      }
                    } else {
                      setState(() {
                        error = 'Неверный пароль';
                      });
                    }
                  },
                  child: const Text('Войти'),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

/// Модель элемента списка пользователей на экране входа.
class _UserItem {
  final String id;
  final String name;
  final String position;
  final String password;
  final bool isTechLeader;
  _UserItem({
    required this.id,
    required this.name,
    required this.position,
    required this.password,
    this.isTechLeader = false,
  });
}