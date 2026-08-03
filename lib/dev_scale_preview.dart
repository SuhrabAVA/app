// ВРЕМЕННЫЙ dev-target для визуальной проверки AppLayoutScale.
// Запуск: flutter run -d windows -t lib/dev_scale_preview.dart
// Клавиши 1/2/3 переключают режимы: ПК-эталон / планшет ДО / планшет ПОСЛЕ.
// Файл удаляется после проверки — в приложение не входит.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'admin_panel.dart';
import 'app_ui_stability.dart';
import 'widgets/app_layout_scale.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await dotenv.load(fileName: '.env');
  await initializeDateFormatting('ru');
  await Supabase.initialize(
    url: dotenv.env['SUPABASE_URL']!,
    anonKey: dotenv.env['SUPABASE_ANON_KEY']!,
  );
  runApp(const _ScalePreviewApp());
}

class _ScalePreviewApp extends StatefulWidget {
  const _ScalePreviewApp();

  @override
  State<_ScalePreviewApp> createState() => _ScalePreviewAppState();
}

class _ScalePreviewAppState extends State<_ScalePreviewApp> {
  int _mode = 0;

  static const _configs = [
    ('1: ПК-эталон 1536x864 (как сейчас на ПК)', Size(1536, 864), false),
    ('2: Планшет 1280x800 — ДО (текущее поведение)', Size(1280, 800), false),
    ('3: Планшет 1280x800 — ПОСЛЕ (AppLayoutScale)', Size(1280, 800), true),
  ];

  @override
  Widget build(BuildContext context) {
    final (label, logicalSize, applyScale) = _configs[_mode];
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Focus(
        autofocus: true,
        onKeyEvent: (node, event) {
          if (event is! KeyDownEvent) return KeyEventResult.ignored;
          final idx = switch (event.logicalKey) {
            LogicalKeyboardKey.digit1 => 0,
            LogicalKeyboardKey.digit2 => 1,
            LogicalKeyboardKey.digit3 => 2,
            _ => -1,
          };
          if (idx < 0) return KeyEventResult.ignored;
          setState(() => _mode = idx);
          return KeyEventResult.handled;
        },
        child: Scaffold(
          backgroundColor: const Color(0xFF202020),
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.all(6),
                child: Text(
                  label,
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                ),
              ),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, c) {
                    final fit = [
                      c.maxWidth / logicalSize.width,
                      c.maxHeight / logicalSize.height,
                      1.0,
                    ].reduce((a, b) => a < b ? a : b);
                    return Align(
                      alignment: Alignment.topLeft,
                      child: SizedBox(
                        width: logicalSize.width * fit,
                        height: logicalSize.height * fit,
                        child: FittedBox(
                          fit: BoxFit.fill,
                          child: SizedBox.fromSize(
                            size: logicalSize,
                            child: _EmbeddedApp(
                              key: ValueKey(_mode),
                              logicalSize: logicalSize,
                              applyScale: applyScale,
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmbeddedApp extends StatelessWidget {
  const _EmbeddedApp({
    super.key,
    required this.logicalSize,
    required this.applyScale,
  });

  final Size logicalSize;
  final bool applyScale;

  @override
  Widget build(BuildContext context) {
    return MediaQuery(
      data: MediaQuery.of(context).copyWith(size: logicalSize),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: appTheme,
        builder: applyScale
            ? (context, child) =>
                AppLayoutScale(child: child ?? const SizedBox.shrink())
            : null,
        home: const AdminPanelScreen(),
      ),
    );
  }
}
