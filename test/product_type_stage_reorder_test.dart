import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sheet_clone/modules/orders/order_handle_type.dart';
import 'package:sheet_clone/modules/orders/product_type_route.dart';
import 'package:sheet_clone/modules/orders/stage_queue_builder.dart';

/// Перестановка этапов маршрута.
///
/// ЗАЧЕМ ОТДЕЛЬНО ОТ ПАРИТЕТНОГО ТЕСТА
/// Паритетный читает фикстуру и сравнивает два сборщика — перестановки он не
/// видит вовсе. А первая версия перестановки маршрут ломала: она раздавала
/// подвижным этапам уровня 0 позиции 1..N подряд, и у П-образного пакета три
/// этапа ручек уезжали с общей позиции 9 на 6, 7 и 8 — прямо в столкновение с
/// под-этапами вариантов. Очередь менялась молча.
///
/// ЧТО ЗДЕСЬ ЗАЩИЩАЕТСЯ
/// Позиция — это РАНГ, а не индекс в списке. Ранг сквозной по обоим уровням, и
/// совпадение рангов осмысленно: этапы одного ранга взаимоисключающие. Отсюда
/// два инварианта, которые тест не даёт потерять:
///   * связка не расклеивается (три ручки, два «Вставка картона»);
///   * под-этап идёт строго после своего переключателя.
void main() {
  final route = _loadRoute('П-образный пакет');

  // Индексы подвижных групп П-образного пакета:
  //   0 Бабинорезка   1 Флексопечать   2 переключатель   3 Резка
  //   4 Резка картона 5 Вставка картона ×2 (ур.1)
  //   6 Сборка дно+картон (ур.1)       7 Склейка дна (ур.1)
  //   8 три этапа ручек
  const iSwitch = 2;
  const iCutting = 3;
  const iCardboardInsert = 5;
  const iHandles = 8;

  group('исходный маршрут', () {
    test('группы собраны по рангам, связки на месте', () {
      final groups = stageGroupsOf(route);
      expect(groups.length, 10, reason: '9 подвижных групп плюс упаковка');

      final byPosition = {for (final g in groups) g.position: g};
      expect(byPosition[6]!.stages.length, 2,
          reason: '«Вставка картона» под двумя автоматами');
      expect(byPosition[9]!.stages.length, 3, reason: 'три этапа ручек');
      expect(byPosition[999]!.isPinned, isTrue);
    });
  });

  group('разрешённые перестановки', () {
    test('под-этапы не разъезжаются, когда двигали не их', () {
      final moved = _apply(route, _allow(route, iCutting, 1));
      final subRanks = _ranksOf(moved, level: 1);

      expect(subRanks.length, 4);
      // Взаимный порядок под-этапов сохранён: «Вставка картона» ×2 на одном
      // ранге, дальше «Сборка дно+картон», дальше «Склейка дна».
      expect(subRanks[0], subRanks[1]);
      expect(subRanks[2], greaterThan(subRanks[1]));
      expect(subRanks[3], greaterThan(subRanks[2]));
    });

    test('связки целы после любой одношаговой перестановки', () {
      for (var i = 0; i < 9; i++) {
        for (final delta in const [-1, 1]) {
          final reorder = reorderStageGroups(route, groupIndex: i, delta: delta);
          if (!reorder.isAllowed) continue;
          final moved = _apply(route, reorder);

          final handles = _positionsOfKeys(moved,
              {'flat_handle_group', 'twisted_handle_group'});
          expect(handles.toSet().length, 1,
              reason: 'ручки обязаны делить один ранг (ход $i/$delta)');

          final inserts = moved.stages
              .where((s) => s.level == 1 && s.title == 'Вставка картона')
              .map((s) => s.position)
              .toSet();
          expect(inserts.length, 1,
              reason: '«Вставка картона» ×2 делят один ранг (ход $i/$delta)');
        }
      }
    });

    test('ранги плотные, упаковка последняя', () {
      final moved = _apply(route, _allow(route, iCutting, 1));
      final ranks = stageGroupsOf(moved)
          .where((g) => !g.isPinned)
          .map((g) => g.position)
          .toList();
      expect(ranks, List<int>.generate(ranks.length, (i) => i + 1));

      final packaging = moved.stages.firstWhere((s) => s.isPinnedLast);
      expect(packaging.position, greaterThan(ranks.last));
    });

    test('общий этап переносится через блок под-этапов', () {
      // «Резка» уходит с ранга 4 за «Склейку дна».
      final moved = _apply(route, _allow(route, iCutting, 4));
      final cutting =
          moved.stages.firstWhere((s) => s.title == 'Резка').position;
      final glue =
          moved.stages.firstWhere((s) => s.title == 'Склейка дна').position;
      expect(cutting, greaterThan(glue));

      // И это видно в собранной очереди: Труба, картон, подрезка.
      final queue = buildOrderStagesFromRoute(
        _draft(moved, tube: true, cardboard: true, trimming: true),
        moved,
      ).map((s) => s.stageName).toList();
      expect(queue.indexOf('Резка'), greaterThan(queue.indexOf('Склейка дна')));
    });
  });

  group('запрещённые перестановки', () {
    test('под-этап нельзя поднять выше переключателя', () {
      final reorder =
          reorderStageGroups(route, groupIndex: iCardboardInsert, delta: -3);
      expect(reorder.isAllowed, isFalse);
      expect(reorder.blockedReason, contains('после переключателя'));
    });

    test('переключатель нельзя опустить ниже своих под-этапов', () {
      final reorder = reorderStageGroups(route, groupIndex: iSwitch, delta: 4);
      expect(reorder.isAllowed, isFalse);
      expect(reorder.blockedReason, contains('после переключателя'));
    });

    test('за пределы списка не двигаем', () {
      expect(reorderStageGroups(route, groupIndex: 0, delta: -1).isAllowed,
          isFalse);
      expect(reorderStageGroups(route, groupIndex: iHandles, delta: 1).isAllowed,
          isFalse);
    });
  });

  group('редактор не может собрать неоднородную группу', () {
    test('любая разрешённая перестановка оставляет группы однородными', () {
      for (var i = 0; i < 9; i++) {
        for (final delta in const [-2, -1, 1, 2]) {
          final reorder = reorderStageGroups(route, groupIndex: i, delta: delta);
          if (!reorder.isAllowed) continue;
          final moved = _apply(route, reorder);

          for (final group in stageGroupsOf(moved)) {
            expect(group.stages.map((s) => s.level).toSet().length, 1,
                reason: 'группа смешала уровни (ход $i/$delta)');
            if (group.level != 1) continue;
            final parents =
                group.stages.map((s) => s.parentVariantId).toSet();
            expect(parents.length, group.stages.length,
                reason: 'под-этапы одного варианта на одном ранге '
                    '(ход $i/$delta)');
          }
        }
      }
    });
  });

  group('регрессия на исходный дефект', () {
    test('сплошная перенумерация уровня 0 столкнула бы ручки с под-этапами',
        () {
      // Так работала первая версия функции: подвижным этапам уровня 0
      // раздавались позиции 1..N подряд, под-этапы не учитывались вовсе.
      final levelZero = route.stages
          .where((s) => s.level == 0 && !s.isPinnedLast)
          .toList()
        ..sort((a, b) {
          final byPosition = a.position.compareTo(b.position);
          return byPosition != 0 ? byPosition : a.key.compareTo(b.key);
        });

      final buggyRanks = <String, int>{};
      for (var i = 0; i < levelZero.length; i++) {
        buggyRanks[levelZero[i].rowId] = i + 1;
      }
      final subRanks =
          route.stages.where((s) => s.level == 1).map((s) => s.position).toSet();
      final handleRanks = levelZero
          .where((s) => s.key.contains('handle') || s.title == 'Вырубка')
          .map((s) => buggyRanks[s.rowId]!)
          .toSet();

      expect(handleRanks.intersection(subRanks), isNotEmpty,
          reason: 'дефект: ручки попадали на ранги под-этапов');
      expect(handleRanks.length, greaterThan(1),
          reason: 'дефект: три ручки расклеивались по разным рангам');

      // Правильный алгоритм этого не делает.
      final moved = _apply(route, _allow(route, iCutting, 1));
      final fixedHandles = _positionsOfKeys(
          moved, {'flat_handle_group', 'twisted_handle_group'}).toSet();
      expect(fixedHandles.length, 1);
      expect(
          fixedHandles.intersection(
              moved.stages.where((s) => s.level == 1).map((s) => s.position).toSet()),
          isEmpty);
    });
  });
}

StageGroupReorder _allow(ProductTypeRoute route, int index, int delta) {
  final reorder = reorderStageGroups(route, groupIndex: index, delta: delta);
  expect(reorder.isAllowed, isTrue,
      reason: 'ход $index/$delta должен быть разрешён: '
          '${reorder.blockedReason}');
  return reorder;
}

/// Применяет результат перестановки к маршруту так же, как это делает
/// `set_product_type_stage_positions`: группам раздаются ранги 1..N,
/// закреплённая упаковка сохраняет свою позицию.
ProductTypeRoute _apply(ProductTypeRoute route, StageGroupReorder reorder) {
  final rankByStageId = <String, int>{};
  for (var i = 0; i < reorder.orderedGroups.length; i++) {
    for (final stageId in reorder.orderedGroups[i]) {
      rankByStageId[stageId] = i + 1;
    }
  }

  return ProductTypeRoute(
    productTypeId: route.productTypeId,
    title: route.title,
    configId: route.configId,
    stages: <RouteStage>[
      for (final stage in route.stages)
        RouteStage(
          rowId: stage.rowId,
          key: stage.key,
          title: stage.title,
          position: rankByStageId[stage.rowId] ?? stage.position,
          level: stage.level,
          parentVariantId: stage.parentVariantId,
          selectionMode: stage.selectionMode,
          isEnabled: stage.isEnabled,
          isPinnedLast: stage.isPinnedLast,
          workplaces: stage.workplaces,
          conditions: stage.conditions,
        ),
    ],
  );
}

List<int> _ranksOf(ProductTypeRoute route, {required int level}) =>
    route.stages.where((s) => s.level == level).map((s) => s.position).toList()
      ..sort();

List<int> _positionsOfKeys(ProductTypeRoute route, Set<String> keys) =>
    route.stages.where((s) => keys.contains(s.key)).map((s) => s.position).toList();

OrderStageQueueDraft _draft(
  ProductTypeRoute route, {
  bool tube = false,
  bool cardboard = false,
  bool trimming = false,
}) {
  final selections = <String, String>{};
  if (tube) {
    final switchStage =
        route.stages.firstWhere((s) => s.key == 'p_main_switch');
    final tubeVariant =
        switchStage.workplaces.firstWhere((w) => w.variantTitle == 'Труба');
    selections[switchStage.key] = tubeVariant.workplaceId;
  }
  return OrderStageQueueDraft(
    productTypeId: route.productTypeId,
    hasPaint: false,
    hasCardboard: cardboard,
    hasTrimming: trimming,
    handleType: OrderHandleType.none,
    requiresBobbinCutting: false,
    selectedSwitchableStageIdsByStageKey: selections,
  );
}

ProductTypeRoute _loadRoute(String title) {
  final file = File('test/fixtures/product_type_routes.json');
  final data = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  final entry = (data['productTypes'] as List)
      .map((e) => Map<String, dynamic>.from(e as Map))
      .firstWhere((e) => e['title'] == title);
  return ProductTypeRoute.fromMap(entry);
}
