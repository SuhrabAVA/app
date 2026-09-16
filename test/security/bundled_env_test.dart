import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Файлы окружения, упакованные в сборку приложения (assets в pubspec.yaml).
///
/// Всё, что лежит в таком файле, достаётся из APK или папки Windows-сборки
/// обычным распаковщиком. 14.09.2026 в упакованном .env нашёлся ключ
/// service_role — полный доступ к базе в обход всех прав. Он был нужен только
/// скриптам и переехал в .env.scripts, который в сборку не попадает.
List<File> _bundledEnvFiles() {
  final pubspec = File('pubspec.yaml').readAsLinesSync();
  return pubspec
      .map((line) => line.trim())
      .where((line) => line.startsWith('- ') && line.contains('.env'))
      .map((line) => File(line.substring(2).trim()))
      .toList(growable: false);
}

/// Ключи, которые приложение действительно читает из .env (main.dart).
const Set<String> _allowedKeys = <String>{
  'SUPABASE_URL',
  'SUPABASE_ANON_KEY',
  'AUTH_EMAIL',
  'AUTH_PASSWORD',
};

void main() {
  test('в сборку не упаковываются лишние секреты', () {
    final files = _bundledEnvFiles().where((f) => f.existsSync()).toList();
    if (files.isEmpty) {
      markTestSkipped('.env нет на этой машине — проверять нечего');
      return;
    }
    for (final file in files) {
      final lines = file.readAsLinesSync();
      for (final raw in lines) {
        final line = raw.trim();
        if (line.isEmpty) continue;
        expect(line.startsWith('#'), isFalse,
            reason: '${file.path}: комментарии тоже попадают в сборку — '
                'заметки с учётными данными держите в .env.scripts');
        final key = line.split('=').first.trim();
        expect(_allowedKeys, contains(key),
            reason: '${file.path}: ключ $key упаковывается в приложение, '
                'но приложению не нужен');
        expect(line.toUpperCase().contains('SERVICE_ROLE'), isFalse,
            reason: '${file.path}: ключ service_role в сборке приложения');
      }
    }
  });
}
