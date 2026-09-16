import 'package:flutter_test/flutter_test.dart';
import 'package:sheet_clone/modules/orders/product_type_execution_options.dart';
import 'package:sheet_clone/modules/orders/product_type_route.dart';
import 'package:sheet_clone/modules/orders/product_type_stage_guards.dart';

/// Правила выбора партнёра и блокировки удаления — без поднятия виджетов.
///
/// Проверяется то же, что validate_product_type_config ловит при публикации:
/// редактор обязан не предлагать выбор, который сервер отвергнет, иначе техлид
/// узнаёт об ошибке через десять действий.

RouteStageWorkplace _wp(String rowId) =>
    RouteStageWorkplace(rowId: rowId, workplaceId: 'w_$rowId');

RouteStage _stage(
  String rowId, {
  required int position,
  int level = 0,
  String? parentVariantId,
  String executionMode = 'sequential',
  String? parallelWithStageId,
  List<RouteStageWorkplace> workplaces = const <RouteStageWorkplace>[],
}) =>
    RouteStage(
      rowId: rowId,
      key: rowId,
      title: rowId,
      position: position,
      level: level,
      parentVariantId: parentVariantId,
      executionMode: executionMode,
      parallelWithStageId: parallelWithStageId,
      workplaces: workplaces,
    );

ProductTypeRoute _route(List<RouteStage> stages) => ProductTypeRoute(
      productTypeId: 'pt',
      title: 'Тип',
      configId: 'cfg',
      stages: stages,
    );

void main() {
  group('eligiblePartners', () {
    test('берёт только этапы строго раньше по рангу', () {
      final first = _stage('first', position: 1);
      final middle = _stage('middle', position: 2);
      final same = _stage('same', position: 3);
      final target = _stage('target', position: 3);
      final later = _stage('later', position: 4);
      final route = _route([first, middle, same, target, later]);

      final ids = eligiblePartners(route, target).map((s) => s.rowId);

      expect(ids, ['first', 'middle']);
      // Ровесник по рангу не годится: этапы одного ранга взаимоисключающие,
      // партнёра в очереди могло не оказаться вовсе.
      expect(ids, isNot(contains('same')));
      expect(ids, isNot(contains('later')));
      expect(ids, isNot(contains('target')));
    });

    test('под-этап чужого варианта не предлагается', () {
      final switcher = _stage('switch', position: 1,
          workplaces: [_wp('vA'), _wp('vB')]);
      final subA =
          _stage('subA', position: 2, level: 1, parentVariantId: 'vA');
      final subB =
          _stage('subB', position: 3, level: 1, parentVariantId: 'vB');
      final route = _route([switcher, subA, subB]);

      final ids = eligiblePartners(route, subB).map((s) => s.rowId);

      // Общий этап верхнего уровня годится — он есть в любой ветке.
      expect(ids, contains('switch'));
      // А под-этап другого варианта при его невыборе не появится никогда.
      expect(ids, isNot(contains('subA')));
    });

    test('под-этап того же варианта годится', () {
      final switcher =
          _stage('switch', position: 1, workplaces: [_wp('vA'), _wp('vB')]);
      final first = _stage('s1', position: 2, level: 1, parentVariantId: 'vA');
      final second = _stage('s2', position: 3, level: 1, parentVariantId: 'vA');
      final route = _route([switcher, first, second]);

      expect(eligiblePartners(route, second).map((s) => s.rowId),
          ['switch', 's1']);
    });

    test('этап верхнего уровня не может ждать под-этап', () {
      final switcher =
          _stage('switch', position: 1, workplaces: [_wp('vA')]);
      final sub = _stage('sub', position: 2, level: 1, parentVariantId: 'vA');
      final common = _stage('common', position: 3);
      final route = _route([switcher, sub, common]);

      final ids = eligiblePartners(route, common).map((s) => s.rowId);

      expect(ids, ['switch']);
      expect(ids, isNot(contains('sub')));
    });
  });

  group('executionSummary', () {
    test('для sequential ничего не показывает', () {
      final stage = _stage('a', position: 1);
      expect(executionSummary(_route([stage]), stage), isNull);
    });

    test('называет партнёра по имени', () {
      final partner = _stage('partner', position: 1);
      final stage = _stage('stage',
          position: 2,
          executionMode: 'parallel_with',
          parallelWithStageId: 'partner');
      expect(executionSummary(_route([partner, stage]), stage),
          'параллельно с «partner»');
    });

    test('не молчит, когда партнёр не выбран', () {
      final stage = _stage('stage', position: 2, executionMode: 'parallel_with');
      expect(executionSummary(_route([stage]), stage),
          'параллельно с этапом: партнёр не выбран');
    });
  });

  group('stageDeleteBlockedReason', () {
    test('без зависимых удаление разрешено', () {
      final a = _stage('a', position: 1);
      final b = _stage('b', position: 2);
      expect(stageDeleteBlockedReason(_route([a, b]), a), isNull);
    });

    test('называет зависимые этапы поимённо', () {
      final partner = _stage('partner', position: 1);
      final dependent = _stage('dependent',
          position: 2,
          executionMode: 'parallel_with',
          parallelWithStageId: 'partner');
      final reason =
          stageDeleteBlockedReason(_route([partner, dependent]), partner);

      expect(reason, isNotNull);
      expect(reason, contains('«dependent»'));
    });

    test('под-этап собственного варианта не блокирует удаление', () {
      // Он уйдёт каскадом вместе с этапом, и его ссылка исчезнет заодно —
      // блокировать удаление из-за него значило бы завести тупик.
      final switcher =
          _stage('switch', position: 1, workplaces: [_wp('vA')]);
      final sub = _stage('sub',
          position: 2,
          level: 1,
          parentVariantId: 'vA',
          executionMode: 'parallel_with',
          parallelWithStageId: 'switch');

      expect(stageDeleteBlockedReason(_route([switcher, sub]), switcher),
          isNull);
    });
  });
}
