import 'package:flutter_test/flutter_test.dart';
import 'package:sheet_clone/modules/orders/material_model.dart';
import 'package:sheet_clone/modules/orders/order_launch_rules.dart';
import 'package:sheet_clone/modules/orders/order_model.dart';
import 'package:sheet_clone/modules/orders/product_model.dart';
import 'package:sheet_clone/modules/warehouse/tmc_model.dart';

void main() {
  OrderModel buildOrder({
    String? stageTemplateId,
    OrderStatus status = OrderStatus.ready_to_start,
    bool assignmentCreated = false,
    double productLength = 10,
    String queueBuildStatus = QueueBuildStatus.built,
  }) {
    return OrderModel(
      id: 'order-1',
      manager: 'manager',
      customer: 'customer',
      orderDate: DateTime(2026, 5, 6),
      dueDate: null,
      product: ProductModel(
        id: 'product-1',
        type: 'Пакет',
        quantity: 100,
        width: 10,
        height: 20,
        depth: 5,
        length: productLength,
      ),
      material: const MaterialModel(id: 'material-1', name: 'Бумага'),
      stageTemplateId: stageTemplateId,
      status: status.name,
      assignmentCreated: assignmentCreated,
      queueBuildStatus: queueBuildStatus,
    );
  }

  const availableMaterial = TmcModel(
    id: 'material-1',
    date: '2026-05-06',
    type: 'paper',
    description: 'Бумага',
    quantity: 20,
    unit: 'м',
  );

  test(
    'allows ready order without stageTemplateId when assignment is not created and material is sufficient',
    () {
      final orderWithoutTemplate = buildOrder();
      final orderWithEmptyTemplate = buildOrder(stageTemplateId: '');

      expect(
        canLaunchOrder(orderWithoutTemplate, const [availableMaterial]),
        isTrue,
      );
      expect(
        canLaunchOrder(orderWithEmptyTemplate, const [availableMaterial]),
        isTrue,
      );
    },
  );

  test('blocks launch when available material is below required length', () {
    final order = buildOrder(stageTemplateId: 'template-1');
    const shortMaterial = TmcModel(
      id: 'material-1',
      date: '2026-05-06',
      type: 'paper',
      description: 'Бумага',
      quantity: 5,
      unit: 'м',
    );

    expect(canLaunchOrder(order, const [shortMaterial]), isFalse);
  });

  test('blocks launch when assignment was already created', () {
    final order = buildOrder(assignmentCreated: true);

    expect(canLaunchOrder(order, const [availableMaterial]), isFalse);
  });

  test('blocks launch until the stage queue is built', () {
    final order = buildOrder(queueBuildStatus: QueueBuildStatus.outdated);

    expect(canLaunchOrder(order, const [availableMaterial]), isFalse);
  });

  group('materialAvailabilityStatus', () {
    test('запущенный заказ дозапускной конвейер не трогает', () {
      // Регрессия: заказ с двумя пройденными этапами уходил в «Ожидание
      // материалов» (его же бумага в резерве → свободный остаток 0), а
      // следующее сохранение — в «Готовы к запуску». Там он и застревал:
      // assignment_created = true, кнопка запуска не работает.
      final launched = buildOrder(
        status: OrderStatus.in_production,
        assignmentCreated: true,
      );

      expect(
        materialAvailabilityStatus(
          order: launched,
          queueBuilt: true,
          hasEnoughMaterial: false,
          materialDataComplete: true,
          requiredBlocksComplete: true,
        ),
        isNull,
      );
      expect(
        materialAvailabilityStatus(
          order: launched,
          queueBuilt: false,
          hasEnoughMaterial: false,
          materialDataComplete: true,
          requiredBlocksComplete: true,
        ),
        isNull,
      );
    });

    test('запущенный заказ поднимается из дозапускного статуса в производство',
        () {
      // Регрессия: заказ выпал в «Ожидание материалов», потом был запущен —
      // и остался там навсегда. Нехватки уже нет, сообщение стёрто, этапы
      // идут, а карточка висит в ожидании: статус не поднимало ничто.
      for (final stuck in <OrderStatus>[
        OrderStatus.waiting_materials,
        OrderStatus.ready_to_start,
        OrderStatus.draft,
      ]) {
        expect(
          materialAvailabilityStatus(
            order: buildOrder(status: stuck, assignmentCreated: true),
            queueBuilt: true,
            hasEnoughMaterial: true,
            materialDataComplete: true,
            requiredBlocksComplete: true,
          ),
          OrderStatus.in_production,
          reason: 'статус $stuck у запущенного заказа — сломанное состояние',
        );
      }
    });

    test('нехватка материала не мешает поднять запущенный заказ', () {
      // У запущенного заказа бумага уже в резерве, поэтому проверка свободного
      // остатка про него ничего не значит — она не должна удерживать его
      // в дозапускном статусе.
      expect(
        materialAvailabilityStatus(
          order: buildOrder(
            status: OrderStatus.waiting_materials,
            assignmentCreated: true,
          ),
          queueBuilt: true,
          hasEnoughMaterial: false,
          materialDataComplete: true,
          requiredBlocksComplete: true,
        ),
        OrderStatus.in_production,
      );
    });

    test('незапущенный заказ без материала уходит в ожидание материалов', () {
      expect(
        materialAvailabilityStatus(
          order: buildOrder(),
          queueBuilt: true,
          hasEnoughMaterial: false,
          materialDataComplete: true,
          requiredBlocksComplete: true,
        ),
        OrderStatus.waiting_materials,
      );
    });

    test('появился материал — из ожидания в готовность к запуску', () {
      expect(
        materialAvailabilityStatus(
          order: buildOrder(status: OrderStatus.waiting_materials),
          queueBuilt: true,
          hasEnoughMaterial: true,
          materialDataComplete: true,
          requiredBlocksComplete: true,
        ),
        OrderStatus.ready_to_start,
      );
    });

    test('несобранная очередь возвращает незапущенный заказ в черновик', () {
      expect(
        materialAvailabilityStatus(
          order: buildOrder(queueBuildStatus: QueueBuildStatus.outdated),
          queueBuilt: false,
          hasEnoughMaterial: true,
          materialDataComplete: true,
          requiredBlocksComplete: true,
        ),
        OrderStatus.draft,
      );
    });

    test('материал без количества роняет заказ в черновик, а не в ожидание',
        () {
      // Пустая «Длина L» или краска без граммовки — не нехватка на складе:
      // материала может быть сколько угодно, недописан сам заказ. Раньше
      // такая позиция читалась всеми проверками как «нехватки нет», и заказ
      // уходил в «Готов к запуску», не проверив материал ни разу.
      for (final status in <OrderStatus>[
        OrderStatus.draft,
        OrderStatus.waiting_materials,
        OrderStatus.ready_to_start,
      ]) {
        expect(
          materialAvailabilityStatus(
            order: buildOrder(status: status),
            queueBuilt: true,
            hasEnoughMaterial: true,
            materialDataComplete: false,
            requiredBlocksComplete: true,
          ),
          OrderStatus.draft,
          reason: 'из $status заказ без количества обязан вернуться в черновик',
        );
      }
    });
  });

  group('materialsWithoutQuantity', () {
    const paperWithLength =
        MaterialModel(id: 'p-1', name: 'МЦБК', quantity: 1200);
    const paperWithoutLength = MaterialModel(id: 'p-2', name: 'ВП');

    test('бумага без «Длины L» и краска без граммовки попадают в список', () {
      expect(
        materialsWithoutQuantity(
          papers: const [paperWithLength, paperWithoutLength],
          paints: const [
            OrderPaintLine(name: '192D Красный', qtyGrams: 3000),
            OrderPaintLine(name: '300i Синий', qtyGrams: null),
            OrderPaintLine(name: '356 new Зелёный', qtyGrams: 0),
          ],
        ),
        <String>['бумага «ВП»', 'краска «300i Синий»', 'краска «356 new Зелёный»'],
      );
    });

    test('полностью заполненный заказ не даёт ни одной позиции', () {
      expect(
        materialsWithoutQuantity(
          papers: const [paperWithLength],
          paints: const [OrderPaintLine(name: '192D Красный', qtyGrams: 3000)],
        ),
        isEmpty,
      );
    });

    test('пустые слоты не считаются позициями заказа', () {
      // Форма заказа держит заготовку строки до того, как сотрудник выберет
      // материал. Заготовка не должна мешать сохранить заказ.
      expect(
        materialsWithoutQuantity(
          papers: const [MaterialModel(id: '', name: '')],
          paints: const [OrderPaintLine(name: '   ', qtyGrams: null)],
        ),
        isEmpty,
      );
    });
  });

  group('paintSelectionMissing', () {
    test('заказ с формой без единой краски печатать нечем', () {
      expect(paintSelectionMissing(hasForm: true, paintLineCount: 0), isTrue);
    });

    test('краска вписана — правило молчит', () {
      expect(paintSelectionMissing(hasForm: true, paintLineCount: 1), isFalse);
    });

    test('заказ без формы краски не требует', () {
      // Печатается не всякое изделие; требовать краску от всех подряд значило
      // бы запереть половину заказов в «Ожидании материалов».
      expect(paintSelectionMissing(hasForm: false, paintLineCount: 0), isFalse);
    });

    test('краска без граммовки — всё равно выбранная краска', () {
      // Незаполненная граммовка роняет заказ в ЧЕРНОВИК
      // (materialsWithoutQuantity), а не в «Ожидание материалов». Считай это
      // правило такую строку отсутствующей — два разных случая слились бы в
      // один статус.
      expect(
        materialsWithoutQuantity(
          papers: const [],
          paints: const [OrderPaintLine(name: '192D Красный', qtyGrams: null)],
        ),
        isNotEmpty,
      );
      expect(paintSelectionMissing(hasForm: true, paintLineCount: 1), isFalse);
    });
  });

  group('isPaintNotSelectedShortage', () {
    test('узнаёт собственную фразу', () {
      expect(
        isPaintNotSelectedShortage(kPaintNotSelectedShortageMessage),
        isTrue,
      );
    });

    test('пустое сообщение — не этот случай', () {
      expect(isPaintNotSelectedShortage(null), isFalse);
      expect(isPaintNotSelectedShortage('   '), isFalse);
    });

    test('когда причин две, серой карточка быть не должна', () {
      // Проверка на укус: нехватка бумаги рядом с невыбранной краской — это
      // уже настоящее ожидание поставки, и прятать его серым нельзя.
      expect(
        isPaintNotSelectedShortage(
          '$kPaintNotSelectedShortageMessage Не хватает 200 м бумаги «Крафт».',
        ),
        isFalse,
      );
    });

    test('обычная нехватка материала фразу не подделывает', () {
      expect(
        isPaintNotSelectedShortage(
          'Недостаточно материала на складе. Пополните склад и запустите '
          'заказ вручную.',
        ),
        isFalse,
      );
    });
  });

  /// Обязательные блоки роняют заказ в черновик так же, как незаполненное
  /// количество: это не нехватка на складе, а недописанный заказ.
  group('materialAvailabilityStatus + обязательные блоки', () {
    OrderModel order({
      String status = 'waiting_materials',
      bool assignmentCreated = false,
    }) =>
        OrderModel(
          id: 'order-1',
          manager: '',
          customer: 'Заказчик',
          orderDate: DateTime.utc(2026, 9, 10),
          dueDate: null,
          product: ProductModel(
            id: 'p',
            type: 'П-пакет',
            quantity: 1,
            width: 1,
            height: 1,
            depth: 1,
          ),
          status: status,
          assignmentCreated: assignmentCreated,
        );

    test('незаполненный обязательный блок не пускает в готовность', () {
      expect(
        materialAvailabilityStatus(
          order: order(),
          queueBuilt: true,
          hasEnoughMaterial: true,
          materialDataComplete: true,
          requiredBlocksComplete: false,
        ),
        OrderStatus.draft,
      );

      // Кусается: тот же заказ с заполненными блоками поднимается.
      expect(
        materialAvailabilityStatus(
          order: order(),
          queueBuilt: true,
          hasEnoughMaterial: true,
          materialDataComplete: true,
          requiredBlocksComplete: true,
        ),
        OrderStatus.ready_to_start,
      );
    });

    test('запущенный заказ правило не трогает', () {
      // Иначе заказ выдернуло бы из производства на первом же сохранении.
      expect(
        materialAvailabilityStatus(
          order: order(status: 'in_production', assignmentCreated: true),
          queueBuilt: true,
          hasEnoughMaterial: true,
          materialDataComplete: true,
          requiredBlocksComplete: false,
        ),
        isNull,
      );
    });
  });
}
