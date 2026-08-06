import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sheet_clone/modules/orders/order_handle_type.dart';
import 'package:sheet_clone/modules/orders/product_type_route.dart';
import 'package:sheet_clone/modules/orders/stage_queue_builder.dart';

/// Паритет зашитого в код автосборщика и сборщика по настройкам типа продукта.
///
/// Фаза 3.2. Новый сборщик стоит РЯДОМ со старым, боевой путь не переключён.
/// Единственный способ убедиться, что перенос 36 правил в данные ничего не
/// потерял, — прогнать оба сборщика на полном произведении входов и сравнить.
///
/// ПОЧЕМУ В СРАВНЕНИЕ ВХОДЯТ ИМЕНА ЭТАПОВ
/// Для переключаемого этапа имя берётся у выбранного варианта
/// (`variantTitle`), а не из `product_type_stages.title`: в старом коде это
/// делает `_selectedName`. В сиде у переключателя В-образных title =
/// «Формирование дна», а оператор обязан видеть «Фри» или «Окно». Сравнивай
/// тест только stage_group_key, порядок и рабочие места — расхождение вышло бы
/// на экран оператора, а тест остался бы зелёным. Поэтому имя в кортеже.
///
/// ПОЧЕМУ СРАВНЕНИЕ ИДЁТ ПОСЛЕ НОРМАЛИЗАЦИИ
/// `normalizeBuiltOrderStageQueue` принудительно переименовывает Бабинорезку,
/// Флексопечать и Упаковку и канонизирует legacy-алиасы. Это общая
/// постобработка обоих сборщиков. Сравнение до неё дало бы три ложных
/// расхождения на каждом типе продукта.
void main() {
  final routes = _loadRoutes();

  test('фикстура маршрутов совпадает с ожидаемым составом', () {
    expect(routes.length, 9, reason: 'девять типов продукта');
    final pShaped = routes.firstWhere((r) => r.title == 'П-образный пакет');
    expect(pShaped.stages.where((s) => s.level == 1).length, 4,
        reason: 'единственный тип с подочередями: два «Вставка картона» под '
            'автоматами и два под-этапа Трубы');
  });

  test('паритет старого и нового сборщика на полном произведении входов', () {
    var total = 0;
    var matched = 0;
    final mismatches = <_Mismatch>[];

    for (final route in routes) {
      for (final variantChoice in _variantChoices(route)) {
        for (final hasPaint in const [false, true]) {
          for (final hasCardboard in const [false, true]) {
            for (final hasTrimming in const [false, true]) {
              for (final handleType in OrderHandleType.values) {
                for (final needsBobbin in const [false, true]) {
                  final draft = OrderStageQueueDraft(
                    productTypeId: route.productTypeId,
                    hasPaint: hasPaint,
                    hasCardboard: hasCardboard,
                    hasTrimming: hasTrimming,
                    handleType: handleType,
                    requiresBobbinCutting: needsBobbin,
                    selectedSwitchableStageIdsByStageKey: variantChoice.byKey,
                  );

                  final oldQueue = _signature(buildOrderStages(draft));
                  final newQueue =
                      _signature(buildOrderStagesFromRoute(draft, route));

                  total += 1;
                  if (_sameQueue(oldQueue, newQueue)) {
                    matched += 1;
                  } else if (mismatches.length < 40) {
                    mismatches.add(_Mismatch(
                      productType: route.title,
                      inputs: 'краски=$hasPaint картон=$hasCardboard '
                          'подрезка=$hasTrimming ручка=${handleType.name} '
                          'бабинорезка=$needsBobbin '
                          'вариант=${variantChoice.label}',
                      oldQueue: oldQueue,
                      newQueue: newQueue,
                    ));
                  }
                }
              }
            }
          }
        }
      }
    }

    if (mismatches.isNotEmpty) {
      final report = StringBuffer()
        ..writeln('Совпало $matched из $total, расхождений '
            '${total - matched}. Первые ${mismatches.length}:');
      for (final m in mismatches) {
        report
          ..writeln('')
          ..writeln('— ${m.productType}: ${m.inputs}')
          ..writeln('  старый: ${m.oldQueue.join(' > ')}')
          ..writeln('  новый:  ${m.newQueue.join(' > ')}');
      }
      fail(report.toString());
    }

    expect(matched, total);
    // Ниже пяти сотен случаев произведение входов не даёт: если счётчик
    // просел, значит фикстура или перебор вариантов урезаны.
    expect(total, greaterThan(500));
  });
}

/// Кортеж сравнения одного этапа: ключ группы, канонический id, имя,
/// множество рабочих мест и выбранное рабочее место.
List<String> _signature(List<BuiltOrderStage> stages) {
  final normalized = normalizeBuiltOrderStageQueue(
    stages.map((s) => s.toMap()).toList(),
  );
  return <String>[
    for (final stage in normalized)
      [
        stage['stageKey'] ?? '',
        stage['stageId'] ?? '',
        stage['stageName'] ?? '',
        (List<String>.from(stage['workplaceIds'] ?? const <String>[])..sort())
            .join(','),
        stage['selectedWorkplaceId'] ?? '',
      ].join('|'),
  ];
}

bool _sameQueue(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Варианты выбора переключаемых этапов: «ничего не выбрано» плюс каждый
/// вариант каждого переключателя. Сегодня у типа не больше одного
/// переключателя, но перебор написан общим.
List<_VariantChoice> _variantChoices(ProductTypeRoute route) {
  final result = <_VariantChoice>[
    const _VariantChoice(label: 'по умолчанию', byKey: <String, String>{}),
  ];
  for (final stage in route.switchableStages) {
    for (final workplace in stage.workplaces) {
      result.add(_VariantChoice(
        label: '${stage.key}=${workplace.variantTitle ?? workplace.workplaceId}',
        byKey: <String, String>{stage.key: workplace.workplaceId},
      ));
    }
  }
  return result;
}

class _VariantChoice {
  const _VariantChoice({required this.label, required this.byKey});
  final String label;
  final Map<String, String> byKey;
}

class _Mismatch {
  const _Mismatch({
    required this.productType,
    required this.inputs,
    required this.oldQueue,
    required this.newQueue,
  });
  final String productType;
  final String inputs;
  final List<String> oldQueue;
  final List<String> newQueue;
}

/// Снимок опубликованных маршрутов, снятый из базы после миграций 20260807.
List<ProductTypeRoute> _loadRoutes() {
  final file = File('test/fixtures/product_type_routes.json');
  final data = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  return <ProductTypeRoute>[
    for (final entry in (data['productTypes'] as List))
      ProductTypeRoute.fromMap(Map<String, dynamic>.from(entry as Map)),
  ];
}
