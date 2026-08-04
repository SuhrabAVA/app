// Обновляет test/fixtures/workplaces_snapshot.json из боевой базы.
//
// Снимок — эталон для test/modules/orders/production_ids_test.dart. Тест
// работает в CI без сети, поэтому справочник в него попадает только через этот
// файл. Запускать вручную, когда техлид добавил или переименовал рабочее место
// либо тип продукта.
//
// Запуск:
//   dart run scripts/refresh_workplaces_snapshot.dart
//
// Читает SUPABASE_URL и SUPABASE_ANON_KEY из .env в корне проекта.

import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  final env = _readEnv(File('.env'));
  final url = env['SUPABASE_URL'];
  final key = env['SUPABASE_ANON_KEY'];
  if (url == null || url.isEmpty || key == null || key.isEmpty) {
    stderr.writeln('В .env нет SUPABASE_URL или SUPABASE_ANON_KEY');
    exitCode = 1;
    return;
  }

  final client = HttpClient();
  try {
    final workplaces =
        await _fetch(client, url, key, 'workplaces?select=id,name&order=name');
    final productTypes = await _fetch(
        client, url, key, 'warehouse_categories?select=id,title&order=title');

    if (workplaces.isEmpty) {
      stderr.writeln('Справочник рабочих мест пуст — снимок не перезаписан');
      exitCode = 1;
      return;
    }

    final payload = <String, dynamic>{
      '_comment': 'Снимок public.workplaces. Обновлять только скриптом '
          'scripts/refresh_workplaces_snapshot.dart. Служит эталоном для '
          'test/modules/orders/production_ids_test.dart и позволяет проверять '
          'константы в CI без доступа к базе.',
      'generated_at': DateTime.now().toUtc().toIso8601String().split('T').first,
      'source': 'public.workplaces (id, name)',
      'workplaces': workplaces
          .map((row) => {'id': row['id'], 'name': row['name']})
          .toList(),
      'product_types': productTypes
          .map((row) => {'id': row['id'], 'title': row['title']})
          .toList(),
    };

    final out = File('test/fixtures/workplaces_snapshot.json');
    out.writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(payload)}\n',
    );
    stdout.writeln('Обновлено: ${out.path}');
    stdout.writeln('  рабочих мест: ${workplaces.length}');
    stdout.writeln('  типов продукта: ${productTypes.length}');
  } finally {
    client.close();
  }
}

Map<String, String> _readEnv(File file) {
  if (!file.existsSync()) return const <String, String>{};
  final result = <String, String>{};
  for (final line in file.readAsLinesSync()) {
    final trimmed = line.trim();
    if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
    final separator = trimmed.indexOf('=');
    if (separator <= 0) continue;
    result[trimmed.substring(0, separator).trim()] =
        trimmed.substring(separator + 1).trim();
  }
  return result;
}

Future<List<Map<String, dynamic>>> _fetch(
  HttpClient client,
  String baseUrl,
  String anonKey,
  String path,
) async {
  final request = await client.getUrl(Uri.parse('$baseUrl/rest/v1/$path'));
  request.headers
    ..set('apikey', anonKey)
    ..set('Authorization', 'Bearer $anonKey');
  final response = await request.close();
  final body = await response.transform(utf8.decoder).join();
  if (response.statusCode != 200) {
    throw HttpException('$path → HTTP ${response.statusCode}: $body');
  }
  return (jsonDecode(body) as List).cast<Map<String, dynamic>>();
}
