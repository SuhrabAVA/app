// lib/main.dart
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'utils/http_overrides.dart';

import 'modules/warehouse/warehouse_provider.dart';
import 'modules/warehouse/supplier_provider.dart';
import 'modules/personnel/personnel_provider.dart';
import 'modules/orders/orders_provider.dart';
import 'modules/production_planning/stage_provider.dart';
import 'modules/tasks/task_provider.dart';
import 'modules/analytics/analytics_provider.dart';
import 'my_app.dart';
// Additional providers for dynamic modules. These providers were previously
// missing from the top‑level MultiProvider, which caused ProviderNotFoundError
// when accessing products or templates in nested screens (e.g. warehouse
// categories or production planning). Including them here makes the
// ProductsProvider and TemplateProvider available throughout the app.
import 'modules/products/products_provider.dart';
import 'modules/production_planning/template_provider.dart';

import 'utils/http_overrides.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 0) MUST be first: apply override before any network clients are created.
  HttpOverrides.global = MyHttpOverrides();

  // Quick runtime check: print effective User-Agent to be sure override works.
  try {
    final ua = HttpClient().userAgent;
    // ignore: avoid_print
    print('✅ Effective User-Agent: ' + (ua ?? 'null'));
  } catch (_) {}

  await dotenv.load(fileName: ".env");

  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details);
    // ignore: avoid_print
    print('🔥 FLUTTER ERROR: ${details.exception}\n${details.stack}');
  };

  await Supabase.initialize(
  url: dotenv.env['SUPABASE_URL']!,
  anonKey: dotenv.env['SUPABASE_ANON_KEY']!,
  headers: {
    // Перебиваем проблемный заголовок на ASCII-строку
    'X-Supabase-Client-Platform-Version': 'Microsoft Windows 11 10.0 (Build 26100)',
  },
);

  // IMPORTANT: on Windows skip signInWithPassword to avoid header-related failures.
  // The anon key/session should be enough to read public data if your RLS permits it.
  if (!Platform.isWindows) {
    final authEmail = dotenv.env['AUTH_EMAIL'];
    final authPassword = dotenv.env['AUTH_PASSWORD'];
    if ((authEmail?.isNotEmpty ?? false) && (authPassword?.isNotEmpty ?? false)) {
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

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => WarehouseProvider()),
        ChangeNotifierProvider(create: (_) => SupplierProvider()),
        ChangeNotifierProvider(create: (_) => PersonnelProvider()),
        ChangeNotifierProvider(create: (_) => OrdersProvider()),
        ChangeNotifierProvider(create: (_) => StageProvider()),
        ChangeNotifierProvider(create: (_) => TaskProvider()),
        ChangeNotifierProvider(create: (_) => AnalyticsProvider()),
        // Register ProductsProvider so that warehouse categories and other
        // modules can read the list of products. Without this provider,
        // attempting to access ProductsProvider via context.watch results in
        // a runtime error (red screen).
        ChangeNotifierProvider(create: (_) => ProductsProvider()),
        // Register TemplateProvider to make production planning templates
        // available throughout the app. Without this, screens like
        // ProductionPlanningScreen and TemplatesScreen cannot access the
        // template list and will throw ProviderNotFoundError.
        ChangeNotifierProvider(create: (_) => TemplateProvider()),
      ],
      child: const MyApp(),
    ),
  );
}
