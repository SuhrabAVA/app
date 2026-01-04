// lib/main.dart
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/date_symbol_data_local.dart';

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

  // 2) Локали для форматирования дат
  await initializeDateFormatting('ru');

  // 3) Ловим Flutter ошибки в консоль
  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details);
    // ignore: avoid_print
    print('🔥 FLUTTER ERROR: ${details.exception}\n${details.stack}');
  };

  // 4) Инициализируем Supabase
  await Supabase.initialize(
    url: dotenv.env['SUPABASE_URL']!,
    anonKey: dotenv.env['SUPABASE_ANON_KEY']!,
    headers: {
      // Почин нестандартного заголовка на Windows
      'X-Supabase-Client-Platform-Version':
          'Microsoft Windows 11 10.0 (Build 26100)',
    },
  );

  // 5) Авто-вход на всех платформах (больше НИЧЕГО не пропускаем на Windows)
  await _ensureSignedInFromEnv();

  // 6) Запускаем приложение с провайдерами
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => WarehouseProvider()),
        ChangeNotifierProvider(create: (_) => SupplierProvider()),
        ChangeNotifierProvider(create: (_) => PersonnelProvider()),
        ChangeNotifierProvider(create: (_) => OrdersProvider()),
        ChangeNotifierProvider(create: (_) => StageProvider()),
        ChangeNotifierProvider(create: (_) => ProductionQueueProvider()),
        ChangeNotifierProvider(create: (_) => TaskProvider()),
        ChangeNotifierProvider(create: (_) => AnalyticsProvider()),
        ChangeNotifierProvider(create: (_) => ProductsProvider()),
        ChangeNotifierProvider(create: (_) => TemplateProvider()),
      ],
      child: const MyApp(),
    ),
  );
}

/// Пытается войти по .env; если пользователя нет — создаёт и входит.
/// Если AUTH_EMAIL / AUTH_PASSWORD не заданы — просто ничего не делает.
Future<void> _ensureSignedInFromEnv() async {
  final authEmail = dotenv.env['AUTH_EMAIL'];
  final authPassword = dotenv.env['AUTH_PASSWORD'];

  if ((authEmail?.isNotEmpty ?? false) && (authPassword?.isNotEmpty ?? false)) {
    final auth = Supabase.instance.client.auth;

    try {
      await auth.signInWithPassword(email: authEmail!, password: authPassword!);
      // ignore: avoid_print
      print('✅ Signed in as $authEmail');
      return;
    } on AuthException catch (e) {
      // ignore: avoid_print
      print('⚠️ signIn failed: ${e.message}. Trying signUp...');
      try {
        await auth.signUp(email: authEmail!, password: authPassword!);
        await auth.signInWithPassword(email: authEmail, password: authPassword);
        // ignore: avoid_print
        print('✅ Signed up & signed in as $authEmail');
        return;
      } catch (e2) {
        // ignore: avoid_print
        print('❌ signUp/signIn retry error: $e2');
      }
    } catch (e, st) {
      // ignore: avoid_print
      print('❌ Auth error: $e\n$st');
    }
  } else {
    // ignore: avoid_print
    print('ℹ️ AUTH_EMAIL/AUTH_PASSWORD не заданы — авто-вход пропущен.');
  }
}
