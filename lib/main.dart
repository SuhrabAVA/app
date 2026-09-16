import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app_ui_stability.dart';
import 'modules/orders/orders_provider.dart';
import 'modules/personnel/personnel_provider.dart';
import 'modules/production/production_queue_provider.dart';
import 'modules/production_planning/stage_provider.dart';
import 'modules/production_planning/template_provider.dart';
import 'modules/products/products_provider.dart';
import 'modules/tasks/task_provider.dart';
import 'modules/warehouse/supplier_provider.dart';
import 'modules/warehouse/warehouse_provider.dart';
import 'my_app.dart';
import 'services/error_log_service.dart';
import 'services/order_edit_http_client.dart';
import 'utils/http_overrides.dart';
import 'widgets/brand_mark.dart';

Future<void> main() async {
  runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();
      debugPaintBaselinesEnabled = false;

      _BootLogger.log('main() started');

      // Глобальный журнал ошибок: перехват debugPrint-логов ошибок
      // и запись всех ошибок в errors_log.txt (см. ErrorLogService).
      ErrorLogService.instance.installDebugPrintHook();
      unawaited(ErrorLogService.instance.init());

      FlutterError.onError = (FlutterErrorDetails details) {
        if (isTransientFlutterVisualAssertion(details)) {
          _BootLogger.log(
            'Suppressed transient Flutter visual assertion: '
            '${details.exceptionAsString()}',
          );
          return;
        }

        ErrorLogService.instance.record(
          source: 'FLUTTER',
          message: details.exceptionAsString(),
          stack: details.stack?.toString(),
          context: details.context?.toDescription() ?? details.library,
        );
        // presentError печатает через debugPrint — глушим хук от дублей.
        ErrorLogService.instance
            .runMuted(() => FlutterError.presentError(details));
        _BootLogger.log(
          'FLUTTER ERROR: ${details.exceptionAsString()}\n${details.stack}',
        );
      };

      PlatformDispatcher.instance.onError = (error, stack) {
        ErrorLogService.instance.record(
          source: 'PLATFORM',
          message: '$error',
          stack: '$stack',
        );
        _BootLogger.log('PLATFORM ERROR: $error\n$stack');
        return true;
      };

      try {
        HttpOverrides.global = MyHttpOverrides();
        _BootLogger.log('HttpOverrides configured');
      } catch (e, st) {
        _BootLogger.log('HttpOverrides setup failed: $e\n$st');
      }

      runApp(const BootstrapApp());
    },
    (error, stackTrace) {
      ErrorLogService.instance.record(
        source: 'ZONE',
        message: '$error',
        stack: '$stackTrace',
      );
      _BootLogger.log('UNCAUGHT ZONE ERROR: $error\n$stackTrace');
    },
  );
}

class BootstrapApp extends StatefulWidget {
  const BootstrapApp({super.key});

  @override
  State<BootstrapApp> createState() => _BootstrapAppState();
}

class _BootstrapAppState extends State<BootstrapApp> {
  bool _isReady = false;
  String? _fatalError;

  @override
  void initState() {
    super.initState();
    // Ждём первый кадр, затем инициализируем тяжёлые async-шаги.
    SchedulerBinding.instance.addPostFrameCallback((_) => _initialize());
  }

  Future<void> _initialize() async {
    try {
      await _step('dotenv.load', () async {
        await dotenv.load(fileName: '.env');
      });

      await _step('initializeDateFormatting(ru)', () async {
        await initializeDateFormatting('ru');
      });

      final supabaseUrl = dotenv.env['SUPABASE_URL'];
      final supabaseAnonKey = dotenv.env['SUPABASE_ANON_KEY'];
      if (supabaseUrl == null || supabaseUrl.isEmpty) {
        throw StateError('SUPABASE_URL is missing in .env');
      }
      if (supabaseAnonKey == null || supabaseAnonKey.isEmpty) {
        throw StateError('SUPABASE_ANON_KEY is missing in .env');
      }

      await _step('Supabase.initialize', () async {
        await Supabase.initialize(
          url: supabaseUrl,
          anonKey: supabaseAnonKey,
          httpClient: OrderEditHttpClient(Uri.parse(supabaseUrl)),
          headers: {
            'X-Supabase-Client-Platform-Version':
                'Microsoft Windows 11 10.0 (Build 26100)',
          },
        );
      });

      await _step('ensureSignedInFromEnv', () async {
        await _ensureSignedInFromEnv().timeout(const Duration(seconds: 12));
      });

      if (!mounted) {
        return;
      }
      setState(() {
        _isReady = true;
        _fatalError = null;
      });
    } catch (e, st) {
      _BootLogger.log('BOOT FAILED: $e\n$st');
      if (!mounted) {
        return;
      }
      setState(() {
        _fatalError = '$e';
      });
    }
  }

  Future<void> _step(String name, Future<void> Function() action) async {
    _BootLogger.log('STEP START: $name');
    await action();
    _BootLogger.log('STEP OK: $name');
  }

  @override
  Widget build(BuildContext context) {
    if (!_isReady) {
      // Экран запуска — первое, что видит сотрудник. Вместо голого индикатора
      // здесь логотип компании: он же дублирует иконку приложения, поэтому
      // запуск не выглядит «безымянным».
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: appTheme,
        home: Scaffold(
          backgroundColor: Colors.white,
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Только логотип: индикатор загрузки здесь не нужен,
                  // инициализация занимает секунды.
                  const AnimatedBrandLockup(height: 104),
                  if (_fatalError != null) ...[
                    const SizedBox(height: 40),
                    Text(
                      'Не удалось запустить приложение:\n$_fatalError',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.red, fontSize: 13),
                    ),
                    const SizedBox(height: 16),
                    ElevatedButton(
                      onPressed: _initialize,
                      child: const Text('Повторить'),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      );
    }

    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => WarehouseProvider()),
        ChangeNotifierProvider(create: (_) => SupplierProvider()),
        ChangeNotifierProvider(create: (_) => PersonnelProvider()),
        // lazy: false — единственный провайдер, которому это нужно.
        //
        // OrdersProvider в конструкторе регистрируется в
        // StockAvailabilityRecheckCoordinator, и это ЕДИНСТВЕННЫЙ обработчик
        // пересчёта обеспеченности заказов. По умолчанию провайдер создаётся
        // при первом обращении, а обращаются к нему только экраны заказов,
        // производства, задач и аналитики. На планшете кладовщика, который
        // открывает один «Склад», провайдера не существовало — приход бумаги
        // или краски проходил, координатор молча возвращал пустой Future, и
        // заказ оставался в «Ожидании материалов». Менеджер за компьютером
        // видел через realtime тот же старый статус: realtime только
        // перечитывает заказы и ничего не пересчитывает.
        ChangeNotifierProvider(create: (_) => OrdersProvider(), lazy: false),
        ChangeNotifierProvider(create: (_) => StageProvider()),
        ChangeNotifierProvider(create: (_) => ProductionQueueProvider()),
        ChangeNotifierProvider(create: (_) => TaskProvider()),
        ChangeNotifierProvider(create: (_) => ProductsProvider()),
        ChangeNotifierProvider(create: (_) => TemplateProvider()),
      ],
      child: const MyApp(),
    );
  }
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
      _BootLogger.log('Signed in as $authEmail');
      return;
    } on AuthException catch (e) {
      _BootLogger.log('signIn failed: ${e.message}. Trying signUp...');
      try {
        await auth.signUp(email: authEmail!, password: authPassword!);
        await auth.signInWithPassword(email: authEmail, password: authPassword);
        _BootLogger.log('Signed up & signed in as $authEmail');
        return;
      } catch (e2, st2) {
        _BootLogger.log('signUp/signIn retry error: $e2\n$st2');
      }
    } catch (e, st) {
      _BootLogger.log('Auth error: $e\n$st');
    }
  } else {
    _BootLogger.log('AUTH_EMAIL/AUTH_PASSWORD отсутствуют — авто-вход пропущен.');
  }
}

class _BootLogger {
  static final File _logFile =
      File('${Directory.systemTemp.path}${Platform.pathSeparator}app_boot.log');

  static void log(String message) {
    final line = '[${DateTime.now().toIso8601String()}] $message';
    // ignore: avoid_print
    print(line);

    try {
      _logFile.writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
    } catch (_) {
      // Не даём логгеру ломать приложение.
    }
  }
}
