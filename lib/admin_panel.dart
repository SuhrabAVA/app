import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'modules/products/products_screen.dart';
import 'modules/production_planning/production_planning_screen.dart';
import 'modules/orders/orders_screen.dart';
import 'modules/personnel/personnel_screen.dart';
import 'modules/production/production_screen.dart';
import 'modules/warehouse/warehouse_screen.dart';
import 'modules/orders/archive_orders_screen.dart';
import 'modules/analytics/analytics_module.dart';
import 'modules/production/problems_board.dart';
import 'modules/tasks/workspace_design.dart';
import 'services/auth_service.dart';
import 'services/audit_log_service.dart';
import 'modules/chat/chat_tab.dart';
// Для выхода и возврата на экран входа
import 'utils/auth_helper.dart';
import 'login_screen.dart';

class AdminPanelScreen extends StatefulWidget {
  const AdminPanelScreen({super.key});

  @override
  State<AdminPanelScreen> createState() => _AdminPanelScreenState();
}

class _AdminPanelScreenState extends State<AdminPanelScreen> {
  static const _anonymousUuid = '00000000-0000-0000-0000-000000000000';
  String? _meName;
  bool _loadingName = true;

  @override
  void initState() {
    super.initState();
    _resolveDisplayName();
  }

  Future<void> _resolveDisplayName() async {
    final user = AuthService.currentUser;
    if (user == null) {
      setState(() {
        _meName = 'Админ';
        _loadingName = false;
      });
      return;
    }

    // 1) сначала берем имя из userMetadata
    String? name = (user.userMetadata?['name'] as String?)?.trim();

    // 2) если его нет — пробуем достать из employees
    if ((name ?? '').isEmpty) {
      final client = Supabase.instance.client;
      try {
        final String? email = user.email as String?;
        final String? uid = user.id as String?;

        // Ищем по login = email ИЛИ по id = uid
        final rows = await client
            .from('documents')
            .select('id, data')
            .eq('collection', 'employees')
            .or(
              "data->>login.eq.${email ?? ''},data->>userId.eq.${uid ?? ''}",
            );
        if (rows is List && rows.isNotEmpty) {
          final r = Map<String, dynamic>.from(rows.first['data'] ?? {});
          final last = (r['lastName'] ?? '').toString().trim();
          final first = (r['firstName'] ?? '').toString().trim();
          final patr = (r['patronymic'] ?? '').toString().trim();
          final full = [last, first, patr]
              .where((s) => s.isNotEmpty)
              .join(' ')
              .trim();
          if (full.isNotEmpty) name = full;
        }
      } catch (_) {
        // тихо игнорируем, fallback ниже
      }
    }

    // 3) финальный fallback — часть email до @
    name ??= ((user.email as String?)?.split('@').first ?? '').trim();
    if ((name ?? '').isEmpty) name = 'Пользователь';

    setState(() {
      _meName = name;
      _loadingName = false;
    });

    // (необязательно) можно закэшировать имя в userMetadata:
    // try {
    //   await Supabase.instance.client.auth.updateUser(
    //     UserAttributes(data: {'name': name}),
    //   );
    // } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final u = AuthService.currentUser;
    final rawId = (u?.id as String?)?.trim();
    final meId = (rawId == null || rawId.isEmpty) ? _anonymousUuid : rawId;
    final isLead =
        (((u?.userMetadata?['role']) ?? (u?.appMetadata?['role'])) == 'lead');

    // Формируем список модулей. Исключаем модуль "Продукция" по требованию.
    final modules = <_AdminModule>[
      const _AdminModule('Склад', '📦', WarehouseDashboard()),
      // _AdminModule('Продукция', '🛍️', const ProductsScreen()), // убрано
      const _AdminModule('Персонал', '👥', PersonnelScreen()),
      const _AdminModule('Заказы', '🧾', OrdersScreen()),
      const _AdminModule('Архив', '📂', ArchiveOrdersScreen()),
      const _AdminModule('Планирование', '🗓️', ProductionPlanningScreen()),
      const _AdminModule('Производство', '🏭', ProductionScreen()),
      _AdminModule(
        'Чат',
        '💬',
        ChatTab(
          currentUserId: meId,
          currentUserName: _meName ?? 'Пользователь', // не-null
          roomId: 'general',
          isLead: isLead,
          // Панель техлида: претензии из чата доступны.
          canCreateClaim: isLead || AuthHelper.isTechLeader,
        ),
      ),
      _AdminModule(
        'Аналитика',
        '📊',
        AnalyticsEntry(
          isTechLeader: AuthHelper.isTechLeader,
          currentEmployeeId:
              AuthHelper.isTechLeader ? null : AuthHelper.currentUserId,
        ),
      ),
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Text('Панель администратора'),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Выйти',
            onPressed: () async {
              final analytics = AuditLogService();
              await analytics.logEvent(
                userId: meId,
                action: 'logout',
                category: 'manager',
              );
              if (!mounted) return;
              // Очищаем авторизацию и переходим на экран входа
              AuthHelper.clear();
              Navigator.of(context).pushAndRemoveUntil(
                MaterialPageRoute(builder: (_) => const LoginScreen()),
                (route) => false,
              );
            },
          ),
        ],
      ),
      backgroundColor: WorkspaceColors.background,
      body: _loadingName
          ? const Center(child: CircularProgressIndicator())
          : LayoutBuilder(
              builder: (context, constraints) {
                // Кнопки занимают левую четверть, но не уходят в крайности:
                // на широком мониторе четверть — это полэкрана пустоты, на
                // планшете 200 px не хватает даже на «Планирование».
                final columnWidth =
                    (constraints.maxWidth * 0.25).clamp(190.0, 300.0);
                final narrow = constraints.maxWidth < 820;

                final menu = _ModuleMenu(modules: modules, narrow: narrow);
                const board = ProblemsBoard();

                if (narrow) {
                  // Узкий экран: кнопки лентой сверху, доска под ними. Колонка
                  // в четверть тут отняла бы у списка всё место.
                  return Padding(
                    padding: const EdgeInsets.all(10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        menu,
                        const SizedBox(height: 10),
                        const Expanded(child: board),
                      ],
                    ),
                  );
                }

                return Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(width: columnWidth, child: menu),
                      const SizedBox(width: 12),
                      const Expanded(child: board),
                    ],
                  ),
                );
              },
            ),
    );
  }
}

/// Модуль главного меню: подпись, значок и экран, который он открывает.
class _AdminModule {
  const _AdminModule(this.label, this.icon, this.page);

  final String label;
  final String icon;
  final Widget page;
}

/// Меню модулей. На широком экране — столбец кнопок во всю ширину колонки,
/// на узком — горизонтальная лента.
class _ModuleMenu extends StatelessWidget {
  const _ModuleMenu({required this.modules, required this.narrow});

  final List<_AdminModule> modules;
  final bool narrow;

  @override
  Widget build(BuildContext context) {
    void open(_AdminModule module) {
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => module.page),
      );
    }

    if (narrow) {
      return SizedBox(
        height: 44,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: modules.length,
          separatorBuilder: (_, __) => const SizedBox(width: 8),
          itemBuilder: (context, index) => _ModuleButton(
            module: modules[index],
            compact: true,
            onTap: () => open(modules[index]),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: workspaceCardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(6, 2, 6, 10),
            child: Text(
              'МОДУЛИ',
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.7,
                color: WorkspaceColors.mutedForeground,
              ),
            ),
          ),
          Expanded(
            child: ListView.separated(
              padding: EdgeInsets.zero,
              itemCount: modules.length,
              separatorBuilder: (_, __) => const SizedBox(height: 6),
              itemBuilder: (context, index) => _ModuleButton(
                module: modules[index],
                compact: false,
                onTap: () => open(modules[index]),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ModuleButton extends StatelessWidget {
  const _ModuleButton({
    required this.module,
    required this.compact,
    required this.onTap,
  });

  final _AdminModule module;
  final bool compact;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: WorkspaceColors.surface,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        hoverColor: WorkspaceColors.primary.withValues(alpha: 0.06),
        child: Container(
          height: compact ? 44 : 46,
          padding: EdgeInsets.symmetric(horizontal: compact ? 14 : 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: WorkspaceColors.border),
          ),
          child: Row(
            mainAxisSize: compact ? MainAxisSize.min : MainAxisSize.max,
            children: [
              Text(module.icon, style: const TextStyle(fontSize: 17)),
              const SizedBox(width: 10),
              // Подпись в одну строку: раньше значок и текст стояли друг под
              // другом в квадратной плитке, и «Планирование» приходилось
              // сокращать до «Планир.».
              compact
                  ? Text(module.label, style: _labelStyle)
                  : Expanded(
                      child: Text(
                        module.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: _labelStyle,
                      ),
                    ),
              if (!compact)
                const Icon(
                  Icons.chevron_right,
                  size: 18,
                  color: WorkspaceColors.disabledForeground,
                ),
            ],
          ),
        ),
      ),
    );
  }

  static const TextStyle _labelStyle = TextStyle(
    fontSize: 13.5,
    fontWeight: FontWeight.w600,
    color: WorkspaceColors.foreground,
  );
}
