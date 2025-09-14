import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

// Import only once from the correct relative location. The `modules` folder
// lives at the same level as `screens`, so we need to go up one directory.
import '../modules/personnel/personnel_provider.dart';
import '../modules/personnel/employee_workspace_screen.dart';
import '../modules/manager/manager_workspace_screen.dart';
import '../modules/personnel/employee_model.dart';
import '../modules/personnel/position_model.dart';
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _searchC = TextEditingController();
  bool isManagerUser(EmployeeModel emp, PersonnelProvider pr) {
      // 1) Прямой ID
    final ids = emp.positionIds.map((e) => e.toString()).toSet();
    if (ids.contains('manager')) return true;

    // 2) По названию должности (если в БД id другой, но есть позиция с именем «Менеджер»)
    final managerPos = pr.positions.firstWhere(
      (p) => p.name.toLowerCase().trim() == 'менеджер',
      orElse: () => PositionModel(id: '', name: ''),
    );
    if (managerPos.id.isNotEmpty && ids.contains(managerPos.id)) return true;

    // 3) На всякий случай — по логину/почте
    final login = emp.login.toLowerCase();
    if (login.contains('manager') || login.contains('менедж')) return true;

    return false;
  }


  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final pr = context.read<PersonnelProvider>();
      await pr.ensureManagerPosition(); // гарантируем должность
      await pr.fetchEmployees();        // подтянуть сотрудников
    });
  }

  @override
  void dispose() {
    _searchC.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Card(
            elevation: 6,
            margin: const EdgeInsets.all(24),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Вход в систему',
                      style: theme.textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      )),
                  const SizedBox(height: 8),
                  Text('Выберите ваше имя для начала работы',
                      style: theme.textTheme.bodyMedium),
                  const SizedBox(height: 16),

                  // Поиск
                  TextField(
                    controller: _searchC,
                    decoration: InputDecoration(
                      prefixIcon: const Icon(Icons.search),
                      hintText: 'Поиск по ФИО или логину',
                      border: const OutlineInputBorder(),
                      isDense: true,
                      suffixIcon: _searchC.text.isEmpty
                          ? null
                          : IconButton(
                              icon: const Icon(Icons.clear),
                              onPressed: () {
                                _searchC.clear();
                                setState(() {});
                              },
                            ),
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                  const SizedBox(height: 16),

                  // Список сотрудников
                  Consumer<PersonnelProvider>(
                    builder: (context, personnel, _) {
                      final query = _searchC.text.trim().toLowerCase();

                      final list = personnel.employees
                          .where((e) => !e.isFired)
                          .where((e) {
                            if (query.isEmpty) return true;
                            final fio =
                                '${e.lastName} ${e.firstName} ${e.patronymic}'
                                    .toLowerCase();
                            // `login` in EmployeeModel is non-nullable so we can call toLowerCase() directly.
                            final login = e.login.toLowerCase();
                            return fio.contains(query) || login.contains(query);
                          })
                          .toList();

                      if (list.isEmpty) {
                        return Padding(
                          padding: const EdgeInsets.only(top: 24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Text('Сотрудники не найдены'),
                              const SizedBox(height: 8),
                              FilledButton.icon(
                                onPressed: () => context
                                    .read<PersonnelProvider>()
                                    .fetchEmployees(),
                                icon: const Icon(Icons.refresh),
                                label: const Text('Обновить'),
                              ),
                            ],
                          ),
                        );
                      }

                      return ListView.separated(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        itemCount: list.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (_, i) {
                          final e = list[i];
                          final fio =
                              '${e.lastName} ${e.firstName} ${e.patronymic}'
                                  .trim();
                          final posName = personnel.positionNameById(
                            e.positionIds.isNotEmpty
                                ? e.positionIds.first
                                : null,
                          );

                          return ListTile(
                            leading: const CircleAvatar(
                              child: Icon(Icons.person_outline),
                            ),
                            title: Text(
                              fio.isEmpty
                                  ? (e.login.trim().isNotEmpty
                                      ? e.login.trim()
                                      : 'Сотрудник')
                                  : fio,
                            ),
                            subtitle: Text(
                              posName.isEmpty ? 'Без должности' : posName,
                            ),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () => _enterAs(e.id),
                          );
                        },
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _enterAs(String employeeId) {
    final pr = context.read<PersonnelProvider>();
    final emp = pr.employees.firstWhere((e) => e.id == employeeId);

    if (isManagerUser(emp, pr)) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => ManagerWorkspaceScreen(employeeId: employeeId),
        ),
      );
    } else {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => EmployeeWorkspaceScreen(employeeId: employeeId),
        ),
      );
    }
}

}
