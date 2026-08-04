import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sheet_clone/modules/orders/production_ids.dart';

/// Сверка реестра id со снимком справочника.
///
/// Работает в CI без доступа к базе: эталон лежит в
/// `test/fixtures/workplaces_snapshot.json` и обновляется скриптом
/// `scripts/refresh_workplaces_snapshot.dart`.
///
/// Ловит ровно тот класс ошибок, из-за которого в проект попали три битые
/// константы: перестановку символов в uuid, скопированном руками.
void main() {
  final snapshotFile = File('test/fixtures/workplaces_snapshot.json');
  final snapshot =
      jsonDecode(snapshotFile.readAsStringSync()) as Map<String, dynamic>;

  final workplacesByUuid = <String, String>{
    for (final row in (snapshot['workplaces'] as List).cast<Map>())
      row['id'].toString(): row['name'].toString(),
  };
  final productTypesByUuid = <String, String>{
    for (final row in (snapshot['product_types'] as List).cast<Map>())
      row['id'].toString(): row['title'].toString(),
  };

  group('Рабочие места', () {
    test('каждый id реестра есть в справочнике', () {
      final missing = kAllWorkplaceIds
          .where((wp) => !workplacesByUuid.containsKey(wp.uuid))
          .map((wp) => '${wp.name} → ${wp.uuid}')
          .toList();
      expect(missing, isEmpty,
          reason: 'id нет в public.workplaces — вероятно опечатка в uuid');
    });

    test('имя в реестре совпадает с именем в справочнике', () {
      final mismatched = <String>[];
      for (final wp in kAllWorkplaceIds) {
        final actual = workplacesByUuid[wp.uuid];
        if (actual == null) continue; // покрыто предыдущим тестом
        if (actual != wp.name) {
          mismatched.add('${wp.uuid}: в реестре «${wp.name}», '
              'в справочнике «$actual»');
        }
      }
      expect(mismatched, isEmpty,
          reason: 'uuid существует, но принадлежит другому рабочему месту — '
              'перестановка символов могла попасть в чужой валидный id');
    });

    test('нет дублей: один uuid — одна константа', () {
      final byUuid = <String, List<String>>{};
      for (final wp in kAllWorkplaceIds) {
        byUuid.putIfAbsent(wp.uuid, () => <String>[]).add(wp.name);
      }
      final duplicates = byUuid.entries.where((e) => e.value.length > 1);
      expect(duplicates, isEmpty,
          reason: 'дублирование — тот самый механизм, который размножил '
              'опечатки: ${duplicates.map((e) => '${e.key} → ${e.value}')}');
    });

    test('нет дублей: одно имя — одна константа', () {
      final byName = <String, int>{};
      for (final wp in kAllWorkplaceIds) {
        byName[wp.name] = (byName[wp.name] ?? 0) + 1;
      }
      expect(byName.entries.where((e) => e.value > 1).map((e) => e.key),
          isEmpty);
    });
  });

  group('Типы продукта', () {
    test('каждый id реестра есть в справочнике категорий', () {
      final missing = kAllProductTypeIds
          .where((pt) => !productTypesByUuid.containsKey(pt.uuid))
          .map((pt) => '${pt.title} → ${pt.uuid}')
          .toList();
      expect(missing, isEmpty);
    });

    test('название совпадает со справочником', () {
      final mismatched = <String>[];
      for (final pt in kAllProductTypeIds) {
        final actual = productTypesByUuid[pt.uuid];
        if (actual == null) continue;
        if (actual != pt.title) {
          mismatched.add('${pt.uuid}: «${pt.title}» vs «$actual»');
        }
      }
      expect(mismatched, isEmpty);
    });

    test('нет дублей', () {
      final uuids = kAllProductTypeIds.map((pt) => pt.uuid).toList();
      expect(uuids.toSet().length, uuids.length);
    });
  });

  group('uuid-литералы только в production_ids.dart', () {
    // Правило распространено и на test/: опечатка `19a67630-8374-49f1-…`
    // вместо `…-4f9f-…` жила именно в ожидании теста и до сих пор
    // правилом не ловилась.
    final uuidPattern = RegExp(
      r"'[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-"
      r"[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'",
    );

    // Файлы вне периметра очереди этапов: там свои справочники (роли,
    // терминалы, демо-данные), к маршрутам производства они не относятся.
    // Вычистим отдельной задачей.
    const allowedOutside = <String>{
      'lib/modules/orders/production_ids.dart',
      'lib/admin_panel.dart',
      'lib/modules/personnel/personnel_provider.dart',
      'lib/modules/personnel/workplaces_screen.dart',
      'lib/modules/production_planning/form_editor_screen.dart',
      // Снимок справочника — это и есть эталон, uuid в нём обязаны быть.
      'test/fixtures/workplaces_snapshot.json',
    };

    List<String> scan(String root) {
      final offenders = <String>[];
      final dir = Directory(root);
      if (!dir.existsSync()) return offenders;
      for (final entity in dir.listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final path = entity.path.replaceAll(r'\', '/');
        if (allowedOutside.contains(path)) continue;
        for (final match in uuidPattern.allMatches(entity.readAsStringSync())) {
          offenders.add('$path: ${match.group(0)}');
        }
      }
      return offenders;
    }

    test('в lib/ нет захардкоженных uuid этапов', () {
      expect(scan('lib'), isEmpty,
          reason: 'uuid объявляются только в production_ids.dart — '
              'дублирование приводит к расхождению значений');
    });

    test('в test/ нет захардкоженных uuid этапов', () {
      expect(scan('test'), isEmpty,
          reason: 'ожидания тестов тоже берут id из реестра: '
              'иначе опечатка в тесте маскирует верную реализацию');
    });
  });
}
