import 'dart:async';

import 'package:flutter/material.dart';

import 'app_ui_stability.dart';
import 'login_screen.dart';
import 'services/connectivity_service.dart';
import 'services/error_log_uploader.dart';
import 'services/realtime_sync_service.dart';
import 'utils/enter_key_behavior.dart';
import 'widgets/app_layout_scale.dart';
import 'widgets/error_overlay.dart';
import 'widgets/offline_overlay.dart';

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
    ConnectivityService.instance.start();
    unawaited(RealtimeSyncService.instance.start());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    ConnectivityService.instance.stop();
    unawaited(RealtimeSyncService.instance.stop());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    RealtimeSyncService.instance.handleLifecycleState(state);
    ConnectivityService.instance.handleLifecycleState(state);
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
      // OfflineOverlayHost стоит ВЫШЕ AppLayoutScale: значок «нет интернета»
      // задан в реальных пикселях экрана и не должен сжиматься вместе с
      // макетом.
      builder: (context, child) => EnterKeyBehavior(
        child: OfflineOverlayHost(
          child: AppLayoutScale(
            child: ErrorOverlayHost(
              child: child ?? const SizedBox.shrink(),
            ),
          ),
        ),
      ),
      home: const LoginScreen(),
    );
  }
}
