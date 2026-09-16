import 'package:flutter_test/flutter_test.dart';
import 'package:sheet_clone/modules/orders/product_type_route.dart';
import 'package:sheet_clone/modules/orders/production_ids.dart';
import 'package:sheet_clone/modules/orders/stage_queue_builder.dart';

/// Заказ должен собираться по маршруту, настроенному в «Типах продукта».
/// До этой правки редактор влиял только на своё превью: очередь настоящего
/// заказа собирали зашитые в код ветки по uuid типа продукта, и публикация
/// маршрута на заказ не действовала.
RouteStage _stage({
  required String rowId,
  required String title,
  required int position,
  required String workplaceId,
}) {
  return RouteStage(
    rowId: rowId,
    key: rowId,
    title: title,
    position: position,
    level: 0,
    workplaces: <RouteStageWorkplace>[
      RouteStageWorkplace(rowId: '$rowId-wp', workplaceId: workplaceId),
    ],
  );
}

void main() {
  // id берём из реестра: захардкоженные uuid в тестах запрещены (см.
  // production_ids_test) — опечатка маскировала бы верную реализацию.
  const productTypeId = ptSheetUuid;

  ProductTypeRoute routeWith(List<RouteStage> stages) => ProductTypeRoute(
        productTypeId: productTypeId,
        title: 'Тестовый тип',
        configId: 'config-1',
        stages: stages,
      );

  List<Map<String, dynamic>> build({ProductTypeRoute? route}) {
    return buildOrderStageQueue(
      productTypeId: productTypeId,
      hasCutting: false,
      hasCardboard: false,
      hasFlexPrinting: false,
      route: route,
    );
  }

  test('очередь берётся из опубликованного маршрута', () {
    final queue = build(
      route: routeWith([
        _stage(
            rowId: 's1', title: 'Печать', position: 1, workplaceId: 'wp-print'),
        _stage(
            rowId: 's2', title: 'Резка', position: 2, workplaceId: 'wp-cut'),
        _stage(
            rowId: 's3',
            title: 'Упаковка',
            position: 3,
            workplaceId: 'wp-pack'),
      ]),
    );

    expect(queue.map((s) => s['stageId']).toList(),
        ['wp-print', 'wp-cut', 'wp-pack']);
  });

  test('порядок этапов маршрута соблюдается', () {
    final queue = build(
      route: routeWith([
        _stage(
            rowId: 's2', title: 'Резка', position: 2, workplaceId: 'wp-cut'),
        _stage(
            rowId: 's1', title: 'Печать', position: 1, workplaceId: 'wp-print'),
      ]),
    );

    expect(queue.map((s) => s['stageId']).toList(), ['wp-print', 'wp-cut']);
  });

  test('выключенный этап в очередь не попадает', () {
    final stages = [
      _stage(rowId: 's1', title: 'Печать', position: 1, workplaceId: 'wp-print'),
      _stage(rowId: 's2', title: 'Резка', position: 2, workplaceId: 'wp-cut'),
    ];
    final disabled = RouteStage(
      rowId: stages[1].rowId,
      key: stages[1].key,
      title: stages[1].title,
      position: stages[1].position,
      level: 0,
      isEnabled: false,
      workplaces: stages[1].workplaces,
    );

    final queue = build(route: routeWith([stages[0], disabled]));
    expect(queue.map((s) => s['stageId']).toList(), ['wp-print']);
  });

  test('без маршрута работает прежняя сборка по типу продукта', () {
    final fallback = build();
    // Зашитые ветки продолжают отвечать: очередь не пустая и не из маршрута.
    expect(fallback, isNotEmpty);
  });

  test('пустой маршрут не обнуляет заказ — остаётся фолбэк', () {
    final withEmptyRoute = build(route: routeWith(const []));
    final fallback = build();

    expect(withEmptyRoute.map((s) => s['stageId']).toList(),
        fallback.map((s) => s['stageId']).toList());
  });
}
