import 'package:flutter/material.dart';

import 'app_ui_stability.dart';
import 'login_screen.dart';
import 'services/error_log_uploader.dart';
import 'utils/enter_key_behavior.dart';
import 'widgets/app_layout_scale.dart';
import 'widgets/error_overlay.dart';

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Досылаем «хвост» прошлой сессии: планшет могли выключить раньше, чем
    // журнал успел уйти на сервер.
    ErrorLogUploader.instance.init();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    // paused — основной сигнал: Android отдаёт его и при сворачивании, и
    // перед выключением устройства. detached приходит не всегда, поэтому
    // рассчитывать только на него нельзя.
    if (state == AppLifecycleState.paused) {
      ErrorLogUploader.instance.flush(reason: 'paused');
    } else if (state == AppLifecycleState.detached) {
      ErrorLogUploader.instance.flush(reason: 'detached');
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: appTheme,
      navigatorKey: appNavigatorKey,
      builder: (context, child) => EnterKeyBehavior(
        child: AppLayoutScale(
          child: ErrorOverlayHost(
            child: child ?? const SizedBox.shrink(),
          ),
        ),
      ),
      home: const LoginScreen(),
    );
  }
}
