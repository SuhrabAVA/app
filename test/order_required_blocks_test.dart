import 'package:flutter_test/flutter_test.dart';
import 'package:sheet_clone/modules/orders/material_model.dart';
import 'package:sheet_clone/modules/orders/order_model.dart';
import 'package:sheet_clone/modules/orders/order_handle_type.dart';
import 'package:sheet_clone/modules/orders/order_required_blocks.dart';
import 'package:sheet_clone/modules/orders/product_model.dart';
import 'package:sheet_clone/modules/orders/product_type_settings.dart';

/// Что считать заполненным и чего не хватает для «Готов к запуску».
///
/// Правило появилось из живого случая: заказ без единой бумаги доезжал до
/// готовности. Проверка обеспеченности его пропускала законно — она отвечает
/// на вопрос «хватает ли выбранного», а выбрано не было ничего.

MaterialModel _paper({String name = 'Бумага', String? id, double qty = 100}) =>
    MaterialModel(id: id, name: name, quantity: qty);

OrderModel _order({
  List<MaterialModel> papers = const <MaterialModel>[],
  String cardboard = 'нет',
  String handle = '-',
  double makeready = 0,
  bool hasForm = false,
  String? pdfUrl,
  List<String> params = const <String>[],
  String? blQuantity,
  double? roll,
}) =>
    OrderModel(
      id: 'order-1',
      manager: 'Менеджер',
      customer: 'Заказчик',
      orderDate: DateTime.utc(2026, 9, 10),
      dueDate: DateTime.utc(2026, 9, 17),
      product: ProductModel(
        id: 'product-1',
        type: 'П-пакет',
        quantity: 1000,
        width: 30,
        height: 20,
        depth: 10,
        blQuantity: blQuantity,
        roll: roll,
      ),
      paperMaterials: papers,
      cardboard: cardboard,
      handle: handle,
      makeready: makeready,
      hasForm: hasForm,
      pdfUrl: pdfUrl,
      additionalParams: params,
    );

Set<String> _filled(
  OrderModel order, {
  int paintLineCount = 0,
  bool hasPdf = false,
}) =>
    filledOrderBlocks(
      order: order,
      paintLineCount: paintLineCount,
      hasPdf: hasPdf,
    );

void main() {
  group('filledOrderBlocks', () {
    test('пустой заказ не заполнил ни одного блока', () {
      expect(_filled(_order()), isEmpty);
    });

    test('выбранная бумага заполняет основную бумагу', () {
      expect(
        _filled(_order(papers: [_paper()])),
        contains(kOrderFormBlockMaterial),
      );
    });

    test('бумага без метража всё равно считается выбранной', () {
      // Разные случаи с разными сообщениями: «не выбрана» и «выбрана, но без
      // количества». Второе ловит materialsWithoutQuantity, и подменять одно
      // другим значит врать менеджеру о причине.
      expect(
        _filled(_order(papers: [_paper(qty: 0)])),
        contains(kOrderFormBlockMaterial),
      );
    });

    test('строка-заготовка позицией не считается', () {
      expect(
        _filled(_order(papers: [_paper(name: '  ', id: '  ')])),
        isNot(contains(kOrderFormBlockMaterial)),
      );
    });

    test('вторая бумага заполняет дополнительные бумаги', () {
      expect(
        _filled(_order(papers: [_paper(), _paper(name: 'Вторая')])),
        contains(kOrderFormBlockExtraPapers),
      );
      // Кусается: одна бумага дополнительной не считается.
      expect(
        _filled(_order(papers: [_paper()])),
        isNot(contains(kOrderFormBlockExtraPapers)),
      );
    });

    test('краски приходят снаружи — их в заказе нет', () {
      expect(
        _filled(_order(), paintLineCount: 1),
        contains(kOrderFormBlockPaints),
      );
      expect(
        _filled(_order(), paintLineCount: 0),
        isNot(contains(kOrderFormBlockPaints)),
      );
    });

    test('«нет» и «-» заполнением не считаются', () {
      final empty = _filled(_order(cardboard: 'нет', handle: '-'));
      expect(empty, isNot(contains(kOrderFormBlockCardboard)));
      expect(empty, isNot(contains(kOrderFormBlockHandle)));

      final filled =
          _filled(_order(cardboard: 'есть', handle: 'Верёвочная'));
      expect(filled, contains(kOrderFormBlockCardboard));
      expect(filled, contains(kOrderFormBlockHandle));
    });

    test('остальные блоки читаются из своих полей', () {
      final order = _order(
        makeready: 2,
        hasForm: true,
        pdfUrl: 'https://example/pdf',
        params: ['Подрезка'],
        blQuantity: '4',
        roll: 700,
      );
      final filled = _filled(order);

      expect(
        filled,
        containsAll(<String>[
          kOrderFormBlockMakeready,
          kOrderFormBlockForm,
          kOrderFormBlockPdf,
          kOrderFormBlockTrimming,
          kOrderFormBlockBlQuantity,
          kOrderFormBlockRoll,
        ]),
      );
    });

    test('PDF засчитывается и по вложению, и по ссылке', () {
      expect(_filled(_order(), hasPdf: true), contains(kOrderFormBlockPdf));
      expect(
        _filled(_order(pdfUrl: 'https://example/pdf')),
        contains(kOrderFormBlockPdf),
      );
    });
  });

  group('missingRequiredBlockCodes', () {
    test('незаполненные обязательные блоки идут в порядке справочника', () {
      final missing = missingRequiredBlockCodes(
        requiredCodes: <String>{
          kOrderFormBlockPaints,
          kOrderFormBlockMaterial,
        },
        filledCodes: const <String>{},
        order: const <String>[
          kOrderFormBlockMaterial,
          kOrderFormBlockCardboard,
          kOrderFormBlockPaints,
        ],
      );

      expect(missing, [kOrderFormBlockMaterial, kOrderFormBlockPaints]);
    });

    test('заполненное обязательное не попадает в список', () {
      expect(
        missingRequiredBlockCodes(
          requiredCodes: <String>{kOrderFormBlockMaterial},
          filledCodes: <String>{kOrderFormBlockMaterial},
        ),
        isEmpty,
      );

      // Кусается: то же требование без заполнения список даёт.
      expect(
        missingRequiredBlockCodes(
          requiredCodes: <String>{kOrderFormBlockMaterial},
          filledCodes: const <String>{},
        ),
        [kOrderFormBlockMaterial],
      );
    });

    test('незаполненное, но НЕ обязательное заказ не держит', () {
      expect(
        missingRequiredBlockCodes(
          requiredCodes: const <String>{},
          filledCodes: const <String>{},
        ),
        isEmpty,
      );
    });

    test('код, которого нет в справочнике релиза, не теряется', () {
      // Справочник живёт в базе и может обогнать приложение. Молча проглотить
      // требование хуже, чем показать его кодом.
      final missing = missingRequiredBlockCodes(
        requiredCodes: <String>{'unknown_block', kOrderFormBlockMaterial},
        filledCodes: const <String>{},
        order: const <String>[kOrderFormBlockMaterial],
      );

      expect(missing, [kOrderFormBlockMaterial, 'unknown_block']);
    });
  });

  group('missingRequiredBlocksMessage', () {
    test('перечисляет названия блоков', () {
      expect(
        missingRequiredBlocksMessage(
          missingCodes: [kOrderFormBlockMaterial, kOrderFormBlockPaints],
          titlesByCode: const <String, String>{
            kOrderFormBlockMaterial: 'Основная бумага',
            kOrderFormBlockPaints: 'Краски',
          },
        ),
        'Не заполнено: Основная бумага, Краски.',
      );
    });

    test('без пропусков сообщения нет', () {
      expect(
        missingRequiredBlocksMessage(
          missingCodes: const <String>[],
          titlesByCode: const <String, String>{},
        ),
        isNull,
      );
    });

    test('незнакомый код показывается как есть, а не пропадает', () {
      expect(
        missingRequiredBlocksMessage(
          missingCodes: const <String>['unknown_block'],
          titlesByCode: const <String, String>{},
        ),
        'Не заполнено: unknown_block.',
      );
    });
  });

  group('ProductTypeSettings.isBlockRequired', () {
    setUp(() => ProductTypeSettings.instance.resetForTesting());
    tearDown(() => ProductTypeSettings.instance.resetForTesting());

    void seed({required bool visible, required bool required}) {
      ProductTypeSettings.instance.seedForTesting(
        types: const [ProductTypeRef(id: 'pt-1', title: 'П-пакет')],
        blocks: const [
          OrderFormBlock(code: kOrderFormBlockMaterial, title: 'Бумага'),
        ],
        publishedByType: const <String, ProductTypeConfig>{
          'pt-1': ProductTypeConfig(
            id: 'cfg-1',
            productTypeId: 'pt-1',
            version: 1,
            status: ProductTypeConfig.statusPublished,
          ),
        },
        visibilityByConfig: <String, Map<String, bool>>{
          'cfg-1': <String, bool>{kOrderFormBlockMaterial: visible},
        },
        requiredByConfig: <String, Map<String, bool>>{
          'cfg-1': <String, bool>{kOrderFormBlockMaterial: required},
        },
      );
    }

    test('отмеченный блок обязателен', () {
      seed(visible: true, required: true);
      expect(
        ProductTypeSettings.instance
            .isBlockRequired('П-пакет', kOrderFormBlockMaterial),
        isTrue,
      );
      expect(
        ProductTypeSettings.instance.requiredBlockCodes('П-пакет'),
        {kOrderFormBlockMaterial},
      );
    });

    test('скрытый блок обязательным не бывает', () {
      // Иначе строка «скрыт и обязателен» заперла бы заказы навсегда: поля в
      // форме нет, заполнить нечем.
      seed(visible: false, required: true);
      expect(
        ProductTypeSettings.instance
            .isBlockRequired('П-пакет', kOrderFormBlockMaterial),
        isFalse,
      );
    });

    test('неизвестный тип продукта ничего не требует', () {
      seed(visible: true, required: true);
      expect(
        ProductTypeSettings.instance
            .isBlockRequired('Неизвестный', kOrderFormBlockMaterial),
        isFalse,
        reason: 'ошибка в эту сторону оставляет прежнее поведение',
      );
    });
  });

  /// Условия сужают требование: блок обязателен, только если условие
  /// выполнено. Появились из живого случая — краска нужна заказу С ФОРМОЙ, а
  /// безусловная галочка заперла бы и непечатные заказы.
  group('blockRequirementApplies', () {
    test('без условий требование действует всегда', () {
      expect(
        blockRequirementApplies(
          conditions: const <OrderBlockCondition>[],
          filledCodes: const <String>{},
        ),
        isTrue,
      );
    });

    test('условие выполнено — требование действует', () {
      expect(
        blockRequirementApplies(
          conditions: const [OrderBlockCondition(predicate: 'has_form')],
          filledCodes: <String>{kOrderFormBlockForm},
        ),
        isTrue,
      );

      // Кусается: без формы то же требование не применяется.
      expect(
        blockRequirementApplies(
          conditions: const [OrderBlockCondition(predicate: 'has_form')],
          filledCodes: const <String>{},
        ),
        isFalse,
      );
    });

    test('отрицание переворачивает условие', () {
      const condition =
          OrderBlockCondition(predicate: 'has_form', negate: true);
      expect(
        blockRequirementApplies(
          conditions: const [condition],
          filledCodes: const <String>{},
        ),
        isTrue,
      );
      expect(
        blockRequirementApplies(
          conditions: const [condition],
          filledCodes: <String>{kOrderFormBlockForm},
        ),
        isFalse,
      );
    });

    test('несколько условий соединяются через И', () {
      const conditions = [
        OrderBlockCondition(predicate: 'has_form'),
        OrderBlockCondition(predicate: 'has_cardboard'),
      ];
      expect(
        blockRequirementApplies(
          conditions: conditions,
          filledCodes: <String>{
            kOrderFormBlockForm,
            kOrderFormBlockCardboard,
          },
        ),
        isTrue,
      );
      expect(
        blockRequirementApplies(
          conditions: conditions,
          filledCodes: <String>{kOrderFormBlockForm},
        ),
        isFalse,
      );
    });

    test('тип ручки сверяется с параметром', () {
      const condition = OrderBlockCondition(
        predicate: 'handle_type_is',
        param: 'twisted',
      );
      expect(
        blockRequirementApplies(
          conditions: const [condition],
          filledCodes: const <String>{},
          handleTypeName: 'twisted',
        ),
        isTrue,
      );
      expect(
        blockRequirementApplies(
          conditions: const [condition],
          filledCodes: const <String>{},
          handleTypeName: 'flat',
        ),
        isFalse,
      );
    });

    test('неизвестный предикат НЕ применяет требование', () {
      // Направление противоположно условиям этапов: тихо запереть заказ в
      // черновике хуже, чем тихо его пропустить.
      expect(
        blockRequirementApplies(
          conditions: const [OrderBlockCondition(predicate: 'from_future')],
          filledCodes: const <String>{},
        ),
        isFalse,
      );
    });
  });

  group('missingRequiredBlocksForOrder', () {
    List<OrderBlockCondition> onlyWithForm(String code) =>
        code == kOrderFormBlockPaints
            ? const [OrderBlockCondition(predicate: 'has_form')]
            : const <OrderBlockCondition>[];

    test('заказ без формы краску не требует', () {
      expect(
        missingRequiredBlocksForOrder(
          requiredCodes: <String>{kOrderFormBlockPaints},
          filledCodes: const <String>{},
          conditionsFor: onlyWithForm,
        ),
        isEmpty,
      );
    });

    test('заказ с формой краску требует', () {
      expect(
        missingRequiredBlocksForOrder(
          requiredCodes: <String>{kOrderFormBlockPaints},
          filledCodes: <String>{kOrderFormBlockForm},
          conditionsFor: onlyWithForm,
        ),
        [kOrderFormBlockPaints],
      );
    });

    test('безусловное требование условие соседа не задевает', () {
      final missing = missingRequiredBlocksForOrder(
        requiredCodes: <String>{
          kOrderFormBlockPaints,
          kOrderFormBlockMaterial,
        },
        filledCodes: const <String>{},
        conditionsFor: onlyWithForm,
        order: const <String>[
          kOrderFormBlockMaterial,
          kOrderFormBlockPaints,
        ],
      );

      expect(missing, [kOrderFormBlockMaterial]);
    });
  });

  group('orderHandleTypeFromDescription', () {
    test('узнаёт кручёную, плоскую и вырубку', () {
      expect(orderHandleTypeFromDescription('Верёвочная крученая').name,
          'twisted');
      expect(orderHandleTypeFromDescription('Плоская ручка').name, 'flat');
      expect(orderHandleTypeFromDescription('Вырубная').name, 'dieCut');
    });

    test('пустое и «-» — тип не выбран', () {
      expect(orderHandleTypeFromDescription(null).name, 'none');
      expect(orderHandleTypeFromDescription('  ').name, 'none');
      expect(orderHandleTypeFromDescription('-').name, 'none');
    });
  });
}
