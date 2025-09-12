import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'modules/products/products_screen.dart';
import 'modules/production_planning/production_planning_screen.dart';
import 'modules/orders/orders_screen.dart';
import 'modules/personnel/personnel_screen.dart';
import 'modules/production/production_screen.dart';
import 'modules/warehouse/warehouse_screen.dart';
import 'modules/orders/archive_orders_screen.dart';
import 'modules/analytics/analytics_screen.dart';
import 'services/auth_service.dart';
import 'modules/chat/chat_tab.dart';
import 'modules/analytics/analytics_provider.dart';
import 'package:provider/provider.dart';
// Для выхода и возврата на экран входа
import 'utils/auth_helper.dart';
import 'login_screen.dart';

class AdminPanelScreen extends StatefulWidget {
  const AdminPanelScreen({super.key});

  @override
  State<AdminPanelScreen> createState() => _AdminPanelScreenState();
}

class _AdminPanelScreenState extends State<AdminPanelScreen> {
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
    if (name == null || name.isEmpty) {
      final client = Supabase.instance.client;
      try {
        final email = user.email;
        final uid = user.id;

        // Ищем по login = email ИЛИ по id = uid
        final rows = await client
            .from('employees')
            .select('firstName, lastName, patronymic, login, id')
            .or('login.eq.$email,id.eq.$uid')
            .limit(1);

        if (rows is List && rows.isNotEmpty) {
          final r = Map<String, dynamic>.from(rows.first);
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
    name ??= (user.email?.split('@').first ?? '').trim();
    if (name.isEmpty) name = 'Пользователь';

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
    final meId = u?.id ?? 'anonymous';
    final isLead =
        ((u?.userMetadata?['role'] ?? u?.appMetadata?['role']) == 'lead');

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
      {'label': '📊\nАналитика', 'page': const AnalyticsScreen()},
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Text('Панель администратора'),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Выйти',
            onPressed: () async {
              final analytics = context.read<AnalyticsProvider>();
              await analytics.logEvent(
                orderId: '',
                stageId: '',
                userId: meId,
                action: 'logout',
                category: 'manager',
              );
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
