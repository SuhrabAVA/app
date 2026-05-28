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
    final modules = [
      {'label': '📦\nСклад', 'page': const WarehouseDashboard()},
      // {'label': '🛍️\nПродукция', 'page': const ProductsScreen()}, // убрано
      {'label': '👥\nПерсонал', 'page': const PersonnelScreen()},
      {'label': '🧾\nЗаказы', 'page': const OrdersScreen()},
      {'label': '📂\nАрхив', 'page': const ArchiveOrdersScreen()},
      {'label': '🗓️\nПланир.', 'page': const ProductionPlanningScreen()},
      {'label': '🏭\nПроизв.', 'page': const ProductionScreen()},
      {
        'label': '💬\nЧат',
        'page': ChatTab(
          currentUserId: meId,
          currentUserName: _meName ?? 'Пользователь', // не-null
          roomId: 'general',
          isLead: isLead,
        ),
      },
      {
        'label': '📊\nАналитика',
        'page': AnalyticsEntry(
          isTechLeader: AuthHelper.isTechLeader,
          currentEmployeeId:
              AuthHelper.isTechLeader ? null : AuthHelper.currentUserId,
        ),
      },
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
      body: _loadingName
          ? const Center(child: CircularProgressIndicator())
          : Padding(
              padding: const EdgeInsets.all(8.0),
              child: GridView.count(
                crossAxisCount: 5,
                crossAxisSpacing: 8,
                mainAxisSpacing: 8,
                childAspectRatio: 1,
                children: modules
                    .map((module) => _buildModuleCard(
                          context,
                          label: module['label'] as String,
                          page: module['page'] as Widget,
                        ))
                    .toList(),
              ),
            ),
    );
  }

  Widget _buildModuleCard(
    BuildContext context, {
    required String label,
    required Widget page,
  }) {
    return GestureDetector(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => page),
      ),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.lightBlue.shade50,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.blueGrey.shade100),
        ),
        padding: const EdgeInsets.all(4),
        child: Center(
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              height: 1.3,
            ),
          ),
        ),
      ),
    );
  }
}
