import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../orders/archive_orders_screen.dart';
import '../orders/orders_screen.dart';
import '../production/production_screen.dart';
import '../chat/chat_tab.dart';
import '../personnel/personnel_provider.dart';
import '../personnel/employee_model.dart';
import '../../services/audit_log_service.dart';
import '../../utils/auth_helper.dart';
import '../../login_screen.dart';

/// Высота шапки рабочего места — она же высота вкладок.
///
/// Заголовок и вкладки стоят в одной строке, а не друг под другом. Стандартная
/// раскладка (`AppBar` 56 px + `TabBar` с иконкой над подписью 72 px) занимала
/// 128 px, и вместе с собственной шапкой открытого модуля данные начинались
/// ниже четверти окна — таблица МУПЗ и списки заказов оставались зажатыми
/// внизу.
const double kManagerWorkspaceHeaderHeight = 52;

/// Вкладка одной строкой: иконка и подпись рядом, а не в столбик.
///
/// Возвращаем именно [Tab]: `TabBar` считает свою высоту, перебирая вкладки и
/// спрашивая `preferredSize`, поэтому обёртка в собственный виджет высоту бы
/// сбросила на стандартную.
Tab _compactTab(IconData icon, String label) => Tab(
      height: kManagerWorkspaceHeaderHeight,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18),
          const SizedBox(width: 8),
          Text(label),
        ],
      ),
    );

/// Шапка рабочего места менеджера: имя, вкладки и выход — одной строкой.
///
/// Вынесена отдельным виджетом, чтобы высоту и раскладку можно было проверить
/// тестом, не поднимая четыре вкладки со всеми их провайдерами.
class ManagerWorkspaceAppBar extends StatelessWidget
    implements PreferredSizeWidget {
  const ManagerWorkspaceAppBar({
    super.key,
    required this.title,
    required this.onLogout,
  });

  final String title;
  final VoidCallback onLogout;

  /// Ниже этой ширины имя не показываем: вкладки важнее — без них не
  /// переключиться, а строка из имени и четырёх вкладок уже не помещается.
  static const double nameBreakpoint = 720;

  @override
  Size get preferredSize =>
      const Size.fromHeight(kManagerWorkspaceHeaderHeight);

  @override
  Widget build(BuildContext context) {
    return AppBar(
      toolbarHeight: kManagerWorkspaceHeaderHeight,
      titleSpacing: 16,
      title: LayoutBuilder(
        builder: (context, constraints) {
          final showName = constraints.maxWidth >= nameBreakpoint;
          return Row(
            children: [
              if (showName) ...[
                // Ширину имени ограничиваем, иначе длинное ФИО отодвигало бы
                // вкладки от центра.
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 320),
                  child: Text(
                    title,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(width: 24),
              ],
              Expanded(
                child: TabBar(
                  isScrollable: true,
                  tabAlignment: TabAlignment.center,
                  labelPadding: const EdgeInsets.symmetric(horizontal: 14),
                  tabs: [
                    _compactTab(Icons.assignment, 'Заказы'),
                    _compactTab(Icons.inventory_2_outlined, 'Архив'),
                    _compactTab(Icons.factory_outlined, 'Производство'),
                    _compactTab(Icons.chat_bubble_outline, 'Чат'),
                  ],
                ),
              ),
            ],
          );
        },
      ),
      actions: [
        IconButton(
          icon: const Icon(Icons.logout),
          tooltip: 'Выйти',
          onPressed: onLogout,
        ),
      ],
    );
  }
}

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
      length: 4,
      child: Scaffold(
        appBar: ManagerWorkspaceAppBar(
          title: fio.isEmpty ? 'Менеджер' : '$fio • Менеджер',
          onLogout: () async {
            final analytics = AuditLogService();
            await analytics.logEvent(
              userId: emp.id,
              action: 'logout',
              category: 'manager',
            );
            AuthHelper.clear();
            if (!context.mounted) return;
            Navigator.of(context).pushAndRemoveUntil(
              MaterialPageRoute(builder: (_) => const LoginScreen()),
              (route) => false,
            );
          },
        ),
        body: TabBarView(
          children: [
            // Полный доступ к заказам
            const OrdersScreen(),
            // Архив — с возобновлением заказов: менеджер оформляет повторы
            // сам, для этого архив ему и нужен.
            const ArchiveOrdersScreen(),
            // МУПЗ на просмотр: менеджеру нужно видеть, где стоят его заказы,
            // но очередь и этапы — зона цеха, а не оформления.
            const ProductionScreen(canManageProduction: false),
            // Отдельная комната менеджеров
            ChatTab(
              currentUserId: emp.id,
              currentUserName: fio.isEmpty ? 'Менеджер' : fio,
              roomId: 'general',    // общий менеджерский чат
              // Рабочее место менеджера: претензии из чата доступны.
              canCreateClaim: true,
            ),
          ],
        ),
      ),
    );
  }
}
