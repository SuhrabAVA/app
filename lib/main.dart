// lib/main.dart
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'utils/http_overrides.dart';
import 'my_app.dart';

// Providers
import 'modules/warehouse/warehouse_provider.dart';
import 'modules/warehouse/supplier_provider.dart';
import 'modules/personnel/personnel_provider.dart';
import 'modules/orders/orders_provider.dart';
import 'modules/production/production_queue_provider.dart';
import 'modules/production_planning/stage_provider.dart';
import 'modules/tasks/task_provider.dart';
import 'modules/analytics/analytics_provider.dart';
import 'modules/products/products_provider.dart';
import 'modules/production_planning/template_provider.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 0) До любых сетевых клиентов
  HttpOverrides.global = MyHttpOverrides();

  // Необязательная проверка User-Agent
  try {
    final ua = HttpClient().userAgent;
    // ignore: avoid_print
    print('✅ Effective User-Agent: ${ua ?? 'null'}');
  } catch (_) {}

  // 1) Загружаем .env
  await dotenv.load(fileName: ".env");

  // 2) Ловим Flutter ошибки в консоль
  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details);
    // ignore: avoid_print
    print('🔥 FLUTTER ERROR: ${details.exception}\n${details.stack}');
  };

  // 3) Инициализируем Supabase
  await Supabase.initialize(
    url: dotenv.env['SUPABASE_URL']!,
    anonKey: dotenv.env['SUPABASE_ANON_KEY']!,
    headers: {
      // Почин нестандартного заголовка на Windows
      'X-Supabase-Client-Platform-Version':
          'Microsoft Windows 11 10.0 (Build 26100)',
    },
  );

  // 4) На Windows пропускаем signInWithPassword (если нужно — авторизуйтесь в рантайме)
  if (!Platform.isWindows) {
    final authEmail = dotenv.env['AUTH_EMAIL'];
    final authPassword = dotenv.env['AUTH_PASSWORD'];
    if ((authEmail?.isNotEmpty ?? false) &&
        (authPassword?.isNotEmpty ?? false)) {
      try {
        await Supabase.instance.client.auth.signInWithPassword(
          email: authEmail!,
          password: authPassword!,
        );
      } catch (e, st) {
        // ignore: avoid_print
        print('❌ Auth signInWithPassword error: $e\n$st');
      }
    }
  } else {
    // ignore: avoid_print
    print('ℹ️ Skipping signInWithPassword on Windows build');
  }

  // 5) Запускаем приложение с провайдерами
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => WarehouseProvider()),
        ChangeNotifierProvider(create: (_) => SupplierProvider()),
        ChangeNotifierProvider(create: (_) => PersonnelProvider()),
        ChangeNotifierProvider(create: (_) => OrdersProvider()),
        ChangeNotifierProvider(create: (_) => ProductionQueueProvider()),
        ChangeNotifierProvider(create: (_) => StageProvider()),
        ChangeNotifierProvider(create: (_) => TaskProvider()),
        ChangeNotifierProvider(create: (_) => AnalyticsProvider()),
        ChangeNotifierProvider(create: (_) => ProductsProvider()),
        ChangeNotifierProvider(create: (_) => TemplateProvider()),
      ],
      child: const MyApp(),
    ),
  );
}
