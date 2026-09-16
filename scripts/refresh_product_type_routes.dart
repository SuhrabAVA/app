// Обновляет test/fixtures/product_type_routes.json из боевой базы.
//
// Снимок — вход паритетного теста test/product_type_route_parity_test.dart,
// который сравнивает зашитый в код автосборщик очереди с новым, работающим по
// настройкам типа продукта. Тест идёт в CI без сети, поэтому маршруты попадают
// в него только через этот файл.
//
// Запускать вручную после того, как техлид ОПУБЛИКОВАЛ новую версию настроек
// типа продукта. Иначе снимок разойдётся с базой: тест останется зелёным на
// устаревших маршрутах, а приложение будет собирать очередь по новым.
//
// ТРЕБУЕТ SERVICE_ROLE И ЗАПУСКАЕТСЯ ТОЛЬКО ЛОКАЛЬНО
// RLS-политики таблиц настроек выданы роли authenticated, поэтому под
// анонимным ключом скрипт получал ноль строк и отказывался перезаписывать
// снимок. Служебный скрипт обслуживания — ровно тот случай, для которого
// заведён service_role: он обходит RLS целиком, не требует входа и не
// расширяет права остальным. Ключ служебный, поэтому запуск только с машины
// разработчика; в CI этот скрипт не место.
//
// Соседний refresh_workplaces_snapshot.dart остаётся на анонимном ключе — у
// workplaces есть политика чтения для anon, и ему service_role не нужен.
//
// Запуск:
//   dart run scripts/refresh_product_type_routes.dart
//
// Читает SUPABASE_URL и SUPABASE_SERVICE_ROLE_KEY из .env в корне проекта.

import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  // Ключ service_role живёт в .env.scripts: .env упакован в сборку приложения.
  final env = _readEnv(File(File('.env.scripts').existsSync() ? '.env.scripts' : '.env'));
  final url = env['SUPABASE_URL'];
  final key = env['SUPABASE_SERVICE_ROLE_KEY'];
  if (url == null || url.isEmpty || key == null || key.isEmpty) {
    stderr.writeln('В .env нет SUPABASE_URL или SUPABASE_SERVICE_ROLE_KEY');
    exitCode = 1;
    return;
  }

  final client = HttpClient();
  try {
    final categories = await _fetch(
        client, url, key, 'warehouse_categories?select=id,title&order=title');
    final configs = await _fetch(client, url, key,
        'product_type_configs?select=id,product_type_id&status=eq.published');
    final stages = await _fetch(
        client,
        url,
        key,
        'product_type_stages?select=id,config_id,parent_variant_id,level,'
            'stage_group_key,title,position,selection_mode,is_enabled,'
            'is_pinned_last');
    final workplaces = await _fetch(
        client,
        url,
        key,
        'product_type_stage_workplaces?select=id,stage_id,workplace_id,'
            'variant_title,is_default,sort_order');
    final conditions = await _fetch(client, url, key,
        'product_type_stage_conditions?select=stage_id,predicate,negate,param_text');

    if (configs.isEmpty || stages.isEmpty) {
      stderr.writeln(
          'В базе нет опубликованных версий или этапов — снимок не перезаписан');
      exitCode = 1;
      return;
    }

    final workplacesByStage = <String, List<Map<String, dynamic>>>{};
    for (final row in workplaces) {
      workplacesByStage
          .putIfAbsent(row['stage_id'].toString(), () => [])
          .add(row);
    }
    final conditionsByStage = <String, List<Map<String, dynamic>>>{};
    for (final row in conditions) {
      conditionsByStage
          .putIfAbsent(row['stage_id'].toString(), () => [])
          .add(row);
    }
    final stagesByConfig = <String, List<Map<String, dynamic>>>{};
    for (final row in stages) {
      stagesByConfig.putIfAbsent(row['config_id'].toString(), () => []).add(row);
    }
    final configByType = <String, Map<String, dynamic>>{
      for (final row in configs) row['product_type_id'].toString(): row,
    };

    final productTypes = <Map<String, dynamic>>[];
    for (final category in categories) {
      final typeId = category['id'].toString();
      final config = configByType[typeId];
      if (config == null) continue;
      final configId = config['id'].toString();

      final stageRows = (stagesByConfig[configId] ?? const [])
          .map((row) => _stageEntry(row, workplacesByStage, conditionsByStage))
          .toList()
        ..sort(_compareStages);

      productTypes.add(<String, dynamic>{
        'id': typeId,
        'title': category['title'],
        'configId': configId,
        'stages': stageRows,
      });
    }

    final payload = <String, dynamic>{
      'note': 'Снимок опубликованных маршрутов типов продукта. Вход '
          'паритетного теста test/product_type_route_parity_test.dart. '
          'Обновлять только скриптом scripts/refresh_product_type_routes.dart '
          'и обязательно после публикации новой версии настроек типа '
          'продукта — иначе тест останется зелёным на устаревших маршрутах.',
      'generated_at': DateTime.now().toUtc().toIso8601String().split('T').first,
      'source': 'product_type_configs (status=published) + product_type_stages '
          '+ product_type_stage_workplaces + product_type_stage_conditions',
      'productTypes': productTypes,
    };

    final out = File('test/fixtures/product_type_routes.json');
    out.writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(payload)}\n',
    );
    stdout.writeln('Обновлено: ${out.path}');
    stdout.writeln('  типов продукта: ${productTypes.length}');
    stdout.writeln('  этапов: ${stages.length}');
  } finally {
    client.close();
  }
}

Map<String, dynamic> _stageEntry(
  Map<String, dynamic> row,
  Map<String, List<Map<String, dynamic>>> workplacesByStage,
  Map<String, List<Map<String, dynamic>>> conditionsByStage,
) {
  final stageId = row['id'].toString();
  final stageWorkplaces = (workplacesByStage[stageId] ?? const [])
      .map((w) => <String, dynamic>{
            'rowId': w['id'],
            'workplaceId': w['workplace_id'],
            'variantTitle': w['variant_title'],
            'isDefault': w['is_default'] == true,
            'sortOrder': (w['sort_order'] as num?)?.toInt() ?? 0,
          })
      .toList()
    ..sort((a, b) {
      final bySort = (a['sortOrder'] as int).compareTo(b['sortOrder'] as int);
      if (bySort != 0) return bySort;
      return '${a['workplaceId']}'.compareTo('${b['workplaceId']}');
    });

  final stageConditions = (conditionsByStage[stageId] ?? const [])
      .map((c) => <String, dynamic>{
            'predicate': c['predicate'],
            'negate': c['negate'] == true,
            'param': c['param_text'],
          })
      .toList()
    ..sort((a, b) {
      final byPredicate = '${a['predicate']}'.compareTo('${b['predicate']}');
      if (byPredicate != 0) return byPredicate;
      return '${a['param']}'.compareTo('${b['param']}');
    });

  return <String, dynamic>{
    'rowId': stageId,
    'key': row['stage_group_key'],
    'title': row['title'],
    'position': (row['position'] as num?)?.toInt() ?? 0,
    'level': (row['level'] as num?)?.toInt() ?? 0,
    'parentVariantId': row['parent_variant_id'],
    'selectionMode': row['selection_mode'],
    'isEnabled': row['is_enabled'] != false,
    'isPinnedLast': row['is_pinned_last'] == true,
    'workplaces': stageWorkplaces,
    'conditions': stageConditions,
  };
}

/// Порядок строк в снимке должен быть устойчивым, иначе diff файла шумит на
/// каждом обновлении.
///
/// Тройки (позиция, уровень, ключ) НЕ ХВАТАЕТ: у П-образного пакета два
/// под-этапа «Вставка картона» делят позицию 6, уровень 1 и ключ — различаются
/// они только вариантом-владельцем. Без последних двух ключей их взаимный
/// порядок определял бы порядок ответа PostgREST, и снимок менялся бы на
/// пустом месте.
int _compareStages(Map<String, dynamic> a, Map<String, dynamic> b) {
  final byPosition = (a['position'] as int).compareTo(b['position'] as int);
  if (byPosition != 0) return byPosition;
  final byLevel = (a['level'] as int).compareTo(b['level'] as int);
  if (byLevel != 0) return byLevel;
  final byKey = '${a['key']}'.compareTo('${b['key']}');
  if (byKey != 0) return byKey;
  final byParent =
      '${a['parentVariantId']}'.compareTo('${b['parentVariantId']}');
  if (byParent != 0) return byParent;
  return '${a['rowId']}'.compareTo('${b['rowId']}');
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
  String serviceRoleKey,
  String path,
) async {
  final request = await client.getUrl(Uri.parse('$baseUrl/rest/v1/$path'));
  request.headers
    ..set('apikey', serviceRoleKey)
    ..set('Authorization', 'Bearer $serviceRoleKey');
  final response = await request.close();
  final body = await response.transform(utf8.decoder).join();
  if (response.statusCode != 200) {
    throw HttpException('$path → HTTP ${response.statusCode}: $body');
  }
  return (jsonDecode(body) as List).cast<Map<String, dynamic>>();
}
