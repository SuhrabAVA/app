import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'modules/chat/chat_provider.dart';
import 'modules/products/products_provider.dart';
import 'admin_panel.dart'; // если не используешь — можешь удалить импорт
import 'my_app.dart';
import 'modules/warehouse/warehouse_provider.dart';
import 'modules/warehouse/supplier_provider.dart';
import 'modules/personnel/personnel_provider.dart';
import 'modules/orders/orders_provider.dart';
import 'modules/production_planning/template_provider.dart';
import 'modules/tasks/task_provider.dart';
import 'modules/analytics/analytics_provider.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 1) Загружаем .env
  await dotenv.load(fileName: ".env");

  // 2) Проверяем, что ключи из .env есть (иначе покажем понятное сообщение)
  final supabaseUrl = dotenv.env['SUPABASE_URL'];
  final supabaseAnon = dotenv.env['SUPABASE_ANON_KEY'];

  if (supabaseUrl == null || supabaseUrl.isEmpty || supabaseAnon == null || supabaseAnon.isEmpty) {
    runApp(const _EnvErrorApp(
      message: 'Отсутствуют SUPABASE_URL / SUPABASE_ANON_KEY в .env',
    ));
    return;
  }

  // 3) Инициализация Supabase (ВАЖНО: имена переменных из .env)
  await Supabase.initialize(
    url: supabaseUrl,
    anonKey: supabaseAnon,
  );

  // 4) Автовход для отладки (нужен из-за RLS). Войдём, если есть логин/пароль в .env
  final authEmail = dotenv.env['AUTH_EMAIL'];
  final authPassword = dotenv.env['AUTH_PASSWORD'];
  final supaAuth = Supabase.instance.client.auth;

  if (supaAuth.currentUser == null &&
      authEmail != null && authEmail.isNotEmpty &&
      authPassword != null && authPassword.isNotEmpty) {
    try {
      await supaAuth.signInWithPassword(email: authEmail, password: authPassword);
    } catch (e, st) {
      debugPrint('❌ Auth signInWithPassword error: $e\n$st');
      // Можно оставить без return — приложение запустится без сессии.
    }
  }

  // 5) Глобальный обработчик ошибок Flutter (чтобы видеть стек)
  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details);
    // ignore: avoid_print
    print('🔥 FLUTTER ERROR: ${details.exception}\n${details.stack}');
  };

  // 6) Запуск приложения с провайдерами
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => WarehouseProvider()),
        ChangeNotifierProvider(create: (_) => PersonnelProvider()),
        ChangeNotifierProvider(create: (_) => OrdersProvider()),
        ChangeNotifierProvider(create: (_) => ProductsProvider()),
        ChangeNotifierProvider(create: (_) => SupplierProvider()),
        ChangeNotifierProvider(create: (_) => TemplateProvider()),
        ChangeNotifierProvider(create: (_) => TaskProvider()),
        ChangeNotifierProvider(create: (_) => AnalyticsProvider()),
        ChangeNotifierProvider(create: (_) => ChatProvider()),
      ],
      child: const MyApp(),
    ),
  );
}

/// Простой экран с сообщением об ошибке окружения (чтобы не было белого экрана)
class _EnvErrorApp extends StatelessWidget {
  final String message;
  const _EnvErrorApp({super.key, required this.message});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 16),
            ),
          ),
        ),
      ),
    );
  }
}
