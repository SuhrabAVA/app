import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'modules/personnel/employee_model.dart'; // EmployeeModel
import 'modules/personnel/personnel_constants.dart'; // kManagerId, kWarehouseHeadId, kTechLeaderId
import 'modules/personnel/position_model.dart'; // PositionModel
import 'modules/manager/manager_workspace_screen.dart';
import 'admin_panel.dart';
import 'modules/personnel/employee_workspace_screen.dart';
import 'modules/personnel/personnel_provider.dart';
import 'modules/personnel/status_shift_screen.dart';
import 'utils/auth_helper.dart';
import 'utils/network_failures.dart';
import 'widgets/brand_mark.dart';
import 'modules/warehouse_manager/warehouse_manager_workspace_screen.dart';
import 'services/audit_log_service.dart';
import 'services/error_log_uploader.dart';
import 'services/auth_extras.dart';
import 'services/employee_password_service.dart';

bool isManagerUser(EmployeeModel emp, PersonnelProvider pr) {
  final ids = emp.positionIds.map((e) => e.toString()).toSet();
  if (ids.contains(kManagerId)) return true;

  final mgr = pr.findManagerPosition();
  if (mgr != null && ids.contains(mgr.id)) return true;

  final loginLower = emp.login.toLowerCase();
  if (loginLower.contains('manager') || loginLower.contains('менедж'))
    return true;

  return false;
}

bool isWarehouseHeadUser(EmployeeModel emp, PersonnelProvider pr) {
  final ids = emp.positionIds.map((e) => e.toString()).toSet();
  if (ids.contains(kWarehouseHeadId)) return true;

  final wh = pr.findWarehouseHeadPosition();
  if (wh != null && ids.contains(wh.id)) return true;

  final loginLower = emp.login.toLowerCase();
  if (loginLower.contains('warehouse') || loginLower.contains('склад'))
    return true;

  return false;
}

String _employeeDisplayName(EmployeeModel emp) {
  final parts = [emp.lastName, emp.firstName, emp.patronymic]
      .map((part) => part.trim())
      .where((part) => part.isNotEmpty);
  final full = parts.join(' ');
  return full.isEmpty ? (emp.login.isEmpty ? 'Сотрудник' : emp.login) : full;
}

String? _statusNameFor(PersonnelProvider personnel, String? statusId) {
  if (statusId == null || statusId.isEmpty) return null;
  for (final status in personnel.statuses) {
    if (status.id == statusId) return status.name;
  }
  return null;
}

/// Сообщение о неудачной записи в `positions`. Обрыв связи и отказ RLS —
/// разные диагнозы: раньше оба писались как «Нет прав», и в журнале ошибок
/// сетевые сбои выглядели как проблема с правами.
String _positionsWriteFailure(String step, Object error) {
  return isTransientNetworkFailure(error)
      ? 'Не удалось записать в positions ($step): нет связи с сервером: $error'
      : 'Нет прав на запись в positions ($step): $error';
}

/// Экран логина.
/// Безопасно работает при включенном RLS: записи создаются только при наличии авторизации.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {

  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  bool _bootstrapping = true;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    try {
      // 1) Пытаемся выполнить бэкенд-вход (если настроен).
      // Техлид — фиксированная должность tech_leader в positions; прежнее
      // «создание техлида» в documents всегда падало (documents.id — uuid).
      try {
        await AuthExtras.tryBackendSignInIfConfigured();
      } catch (_) {
        // не критично
      }

      // 2) После первого кадра — подгружаем данные
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        // Кадр может прийти уже после dispose (быстрый выход с экрана,
        // сворачивание приложения на старте). Тогда State.context бросает
        // «Null check operator used on a null value» — читаем провайдер
        // только пока элемент жив.
        if (!mounted) return;
        final pr = context.read<PersonnelProvider>();

        // ВАЖНО: ensure* — только если есть авторизованный пользователь,
        // иначе RLS (auth.uid() = NULL) заблокирует insert.
        final currentUser = Supabase.instance.client.auth.currentUser;
        if (currentUser != null) {
          try {
            await pr.ensureManagerPosition();
          } catch (e) {
            debugPrint(_positionsWriteFailure('ensureManagerPosition', e));
          }
          try {
            await pr.ensureWarehouseHeadPosition();
          } catch (e) {
            debugPrint(_positionsWriteFailure('ensureWarehouseHeadPosition', e));
          }
          try {
            await pr.ensureCmmSpecialistPosition();
          } catch (e) {
            debugPrint(_positionsWriteFailure('ensureCmmSpecialistPosition', e));
          }
        }

        // Всегда пробуем получить сотрудников (для чтения обычно есть политика)
        try {
          await pr.fetchEmployees();
        } catch (e) {
          debugPrint(
            isTransientNetworkFailure(e)
                ? 'Сотрудники не загружены: нет связи с сервером: $e'
                : 'Нет прав на чтение сотрудников. Проверьте RLS: $e',
          );
        }

        if (mounted) {
          setState(() => _bootstrapping = false);
        }
      });
    } finally {
      // на случай если addPostFrameCallback не сработал
      if (mounted) {
        setState(() => _bootstrapping = false);
      }
    }
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
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
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
                  // Логотип над поиском и списком. Компактный: карточка
                  // входа и так узкая, а место нужно списку сотрудников.
                  const Center(
                    child: Padding(
                      padding: EdgeInsets.only(bottom: 14),
                      child: BrandLockup(height: 40),
                    ),
                  ),
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
                  if (_bootstrapping)
                    const Center(child: CircularProgressIndicator())
                  else
                    Consumer<PersonnelProvider>(
                      builder: (context, personnel, _) {
                        final List<_UserItem> users = [];

                        for (final e in personnel.employees) {
                          if (e.isFired) continue;

                          String positionName = '';
                          if (e.positionIds.isNotEmpty) {
                            final match = personnel.positions.firstWhere(
                              (p) => p.id == e.positionIds.first,
                              orElse: () => PositionModel(id: '', name: ''),
                            );
                            positionName = match.name;
                          }

                          final fullName =
                              '${e.lastName} ${e.firstName} ${e.patronymic}'
                                  .trim();

                          users.add(_UserItem(
                            id: e.id,
                            name: fullName.isEmpty ? 'Без имени' : fullName,
                            position: positionName,
                            password: e.password,
                            photoUrl: e.photoUrl,
                            isTechLeader: e.positionIds.contains(kTechLeaderId),
                          ));
                        }

                        final query = _searchQuery.toLowerCase();
                        final filtered = users
                            .where((u) =>
                                u.name.toLowerCase().contains(query) ||
                                u.position.toLowerCase().contains(query))
                            .toList();

                        if (personnel.employees.isEmpty) {
                          return Column(
                            children: [
                              const SizedBox(height: 8),
                              const Text(
                                'Список пользователей пуст или недоступен.',
                                style: TextStyle(fontSize: 13),
                                textAlign: TextAlign.center,
                              ),
                              const SizedBox(height: 8),
                              ElevatedButton.icon(
                                onPressed: () async {
                                  try {
                                    await context
                                        .read<PersonnelProvider>()
                                        .fetchEmployees();
                                  } catch (_) {}
                                },
                                icon: const Icon(Icons.refresh),
                                label: const Text('Обновить'),
                              ),
                            ],
                          );
                        }

                        if (filtered.isEmpty) {
                          return const Center(
                              child: Text('Пользователи не найдены'));
                        }

                        return SizedBox(
                          height: 300,
                          child: ListView.separated(
                            itemCount: filtered.length,
                            separatorBuilder: (_, __) =>
                                const SizedBox(height: 8),
                            itemBuilder: (context, index) {
                              final user = filtered[index];
                              return InkWell(
                                onTap: () => _promptPassword(context, user),
                                borderRadius: BorderRadius.circular(8),
                                child: Container(
                                  decoration: BoxDecoration(
                                    border:
                                        Border.all(color: Colors.grey.shade300),
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
                                            (user.photoUrl != null && user.photoUrl!.isNotEmpty)
                                                ? NetworkImage(user.photoUrl!)
                                                : null,
                                        child: (user.photoUrl == null ||
                                                user.photoUrl!.isEmpty)
                                            ? const Icon(
                                                Icons.person_outline,
                                                color: Colors.grey,
                                              )
                                            : null,
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
                                              user.position.isEmpty
                                                  ? (user.isTechLeader
                                                      ? 'Технический лидер'
                                                      : 'Сотрудник')
                                                  : user.position,
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
                        );
                      },
                    ),
                ],
                  ),
                ),
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
    final passwordAccepted = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _PasswordDialog(user: user),
    );

    if (passwordAccepted != true || !mounted) {
      return;
    }

    final rootNavigator = Navigator.of(context);
    final personnel = context.read<PersonnelProvider>();

    // Запоминаем пользователя.
    if (user.isTechLeader) {
      AuthHelper.setTechLeader(name: user.name);
    } else {
      AuthHelper.setEmployee(id: user.id, name: user.name);
    }

    // Логируем вход.
    final analytics = AuditLogService();
    final emp = user.isTechLeader
        ? null
        : personnel.employees.firstWhere(
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
    final category = user.isTechLeader
        ? 'manager'
        : isManagerUser(emp!, personnel)
            ? 'manager'
            : isWarehouseHeadUser(emp, personnel)
                ? 'warehouse'
                : 'production';

    await analytics.logEvent(
      userId: user.id,
      action: 'login',
      category: category,
    );

    if (!mounted) {
      return;
    }

    FocusManager.instance.primaryFocus?.unfocus();

    if (user.isTechLeader) {
      rootNavigator.pushReplacement(
        MaterialPageRoute(
          builder: (_) => const AdminPanelScreen(),
        ),
      );
    } else {
      // Сотрудник со статусом и без должности (уборщик, охранник) заданий не
      // выполняет — производственное рабочее пространство ему показывать
      // нечем. Такому нужен только экран отметки прихода/ухода.
      final statusId = personnel.currentStatusIdFor(user.id);
      final statusOnly = isStatusOnlyEmployee(
        positionIds: emp!.positionIds,
        statusId: statusId,
      );

      final screen = statusOnly
          ? StatusShiftScreen(
              employeeId: user.id,
              employeeName: _employeeDisplayName(emp),
              statusName: _statusNameFor(personnel, statusId),
              onExit: () async {
                await analytics.logEvent(
                  userId: user.id,
                  action: 'logout',
                  category: 'production',
                );
                ErrorLogUploader.instance.flush(reason: 'logout');
                AuthHelper.clear();
                if (!rootNavigator.mounted) return;
                rootNavigator.pushAndRemoveUntil(
                  MaterialPageRoute(builder: (_) => const LoginScreen()),
                  (route) => false,
                );
              },
            )
          : isManagerUser(emp, personnel)
              ? ManagerWorkspaceScreen(employeeId: user.id)
              : isWarehouseHeadUser(emp, personnel)
                  ? WarehouseManagerWorkspaceScreen(employeeId: user.id)
                  : EmployeeWorkspaceScreen(employeeId: user.id);

      rootNavigator.pushReplacement(
        MaterialPageRoute(builder: (_) => screen),
      );
    }
  }
}


class _PasswordDialog extends StatefulWidget {
  final _UserItem user;

  const _PasswordDialog({required this.user});

  @override
  State<_PasswordDialog> createState() => _PasswordDialogState();
}

class _PasswordDialogState extends State<_PasswordDialog> {
  final TextEditingController _controller = TextEditingController();
  String? _error;
  bool _isSubmitting = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_isSubmitting) {
      return;
    }

    setState(() {
      _isSubmitting = true;
      _error = null;
    });

    // Пароль сверяет сервер по хешу (employee_verify_password). Локальный
    // пароль из списка сотрудников нужен только на случай обрыва связи.
    String? error;
    try {
      final check = await verifyEmployeePassword(
        employeeId: widget.user.id,
        input: _controller.text,
        cachedPassword: widget.user.password,
      );
      error = passwordCheckError(check);
    } catch (e) {
      error = 'Не удалось проверить пароль: $e';
    }
    if (!mounted) return;

    if (error == null) {
      Navigator.of(context).pop(true);
      return;
    }

    setState(() {
      _error = error;
      _isSubmitting = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: <ShortcutActivator, Intent>{
        const SingleActivator(LogicalKeyboardKey.escape): const DismissIntent(),
        const SingleActivator(LogicalKeyboardKey.enter): const ActivateIntent(),
        const SingleActivator(LogicalKeyboardKey.numpadEnter):
            const ActivateIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          DismissIntent: CallbackAction<DismissIntent>(
            onInvoke: (_) {
              if (!_isSubmitting) {
                Navigator.of(context).pop(false);
              }
              return null;
            },
          ),
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              _submit();
              return null;
            },
          ),
        },
        child: AlertDialog(
          title: Text('Введите пароль для ${widget.user.name}'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _controller,
                autofocus: true,
                obscureText: true,
                enabled: !_isSubmitting,
                decoration: const InputDecoration(labelText: 'Пароль'),
                onSubmitted: _isSubmitting ? null : (_) => _submit(),
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
              onPressed:
                  _isSubmitting ? null : () => Navigator.of(context).pop(false),
              child: const Text('Отмена'),
            ),
            ElevatedButton(
              onPressed: _isSubmitting ? null : _submit,
              child: _isSubmitting
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Войти'),
            ),
          ],
        ),
      ),
    );
  }
}

class _UserItem {
  final String id;
  final String name;
  final String position;
  final String password;
  final String? photoUrl;
  final bool isTechLeader;

  _UserItem({
    required this.id,
    required this.name,
    required this.position,
    required this.password,
    this.photoUrl,
    this.isTechLeader = false,
  });
}
