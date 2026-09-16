import 'package:flutter_test/flutter_test.dart';
import 'package:sheet_clone/modules/orders/product_type_route.dart';
import 'package:sheet_clone/modules/orders/production_ids.dart';
import 'package:sheet_clone/modules/orders/stage_queue_builder.dart';

/// Переключатель варианта у этапов, заведённых в редакторе типов продукта.
///
/// Зашитый сборщик принимал выбор только для двух легаси-этапов и всё
/// остальное молча выбрасывал: у своего этапа («Высечка А1/А2») переключение
/// не меняло ничего.
ProductTypeRoute _route({required bool switchable}) => ProductTypeRoute(
      productTypeId: ptSheetUuid,
      title: 'Влажные салфетки',
      configId: 'config-1',
      stages: <RouteStage>[
        RouteStage(
          rowId: 'row-die',
          key: 'die-cut',
          title: 'Высечка',
          position: 2,
          level: 0,
          selectionMode: switchable ? 'one_of' : 'all',
          workplaces: const <RouteStageWorkplace>[
            RouteStageWorkplace(
              rowId: 'v1',
              workplaceId: 'wp-die-a1',
              variantTitle: 'Высечка А1',
            ),
            RouteStageWorkplace(
              rowId: 'v2',
              workplaceId: 'wp-die-a2',
              variantTitle: 'Высечка А2',
            ),
          ],
        ),
      ],
    );

void main() {
  group('isRouteSwitchableStageKey', () {
    test('переключаемый этап маршрута распознаётся по своему ключу', () {
      expect(
        isRouteSwitchableStageKey(_route(switchable: true), 'die-cut'),
        isTrue,
        reason: 'иначе карточка этапа не станет нажимаемой',
      );
    });

    test('непереключаемый этап нажимать нечего', () {
      expect(
        isRouteSwitchableStageKey(_route(switchable: false), 'die-cut'),
        isFalse,
      );
    });

    test('этап с одним вариантом не переключается', () {
      final single = ProductTypeRoute(
        productTypeId: ptSheetUuid,
        title: 'Влажные салфетки',
        configId: 'config-1',
        stages: <RouteStage>[
          RouteStage(
            rowId: 'row-die',
            key: 'die-cut',
            title: 'Высечка',
            position: 2,
            level: 0,
            selectionMode: 'one_of',
            workplaces: const <RouteStageWorkplace>[
              RouteStageWorkplace(rowId: 'v1', workplaceId: 'wp-die-a1'),
            ],
          ),
        ],
      );
      expect(isRouteSwitchableStageKey(single, 'die-cut'), isFalse);
    });

    test('чужой ключ и отсутствие маршрута', () {
      expect(isRouteSwitchableStageKey(_route(switchable: true), 'other'),
          isFalse);
      expect(isRouteSwitchableStageKey(null, 'die-cut'), isFalse);
      expect(isRouteSwitchableStageKey(_route(switchable: true), '  '),
          isFalse);
    });
  });

  test('выбранный вариант этапа маршрута читается из очереди', () {
    final selections = collectRouteSwitchableSelections(
      _route(switchable: true),
      const [
        {'stageKey': 'die-cut', 'selectedWorkplaceId': 'wp-die-a2'},
      ],
    );

    expect(selections, {'die-cut': 'wp-die-a2'});
  });

  test('чужой вариант не принимается', () {
    final selections = collectRouteSwitchableSelections(
      _route(switchable: true),
      const [
        {'stageKey': 'die-cut', 'selectedWorkplaceId': 'wp-foreign'},
      ],
    );

    expect(selections, isEmpty,
        reason: 'вариант обязан принадлежать этому этапу маршрута');
  });

  test('непереключаемый этап выбора не имеет', () {
    final selections = collectRouteSwitchableSelections(
      _route(switchable: false),
      const [
        {'stageKey': 'die-cut', 'selectedWorkplaceId': 'wp-die-a2'},
      ],
    );

    expect(selections, isEmpty);
  });

  test('без маршрута ничего не собирается', () {
    expect(
      collectRouteSwitchableSelections(null, const [
        {'stageKey': 'die-cut', 'selectedWorkplaceId': 'wp-die-a2'},
      ]),
      isEmpty,
    );
  });

  test('читается и снимок из БД со snake_case', () {
    final selections = collectRouteSwitchableSelections(
      _route(switchable: true),
      const [
        {'stage_key': 'die-cut', 'selected_workplace_id': 'wp-die-a1'},
      ],
    );

    expect(selections, {'die-cut': 'wp-die-a1'});
  });

  test('выбор доходит до сборки очереди и меняет рабочее место', () {
    final route = _route(switchable: true);

    List<BuiltOrderStage> build(String? selected) => buildOrderStagesFromRoute(
          OrderStageQueueDraft(
            productTypeId: ptSheetUuid,
            hasPaint: false,
            hasTrimming: false,
            hasCardboard: false,
            selectedSwitchableStageIdsByStageKey: <String, String>{
              if (selected != null) 'die-cut': selected,
            },
          ),
          route,
        );

    expect(build(null).single.selectedWorkplaceId, 'wp-die-a1',
        reason: 'без выбора берётся первый вариант');
    expect(build('wp-die-a2').single.selectedWorkplaceId, 'wp-die-a2');
    // Имя этапа в очереди — у выбранного варианта, иначе оператор увидит
    // прежний станок.
    expect(build('wp-die-a2').single.stageName, 'Высечка А2');
  });
}
