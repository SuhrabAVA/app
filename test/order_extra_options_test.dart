import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sheet_clone/modules/orders/order_extra_options.dart';
import 'package:sheet_clone/modules/orders/order_model.dart';
import 'package:sheet_clone/modules/orders/product_model.dart';

/// Правила дополнительных опций заказа — без поднятия виджетов.
///
/// Главное, что здесь проверяется, — обещание заказчику: выбранное значение
/// переживает любую правку справочника. Поэтому почти каждый тест сначала
/// портит справочник (переименование, снятие с учёта, удаление), а затем
/// смотрит, что сохранённый заказ по-прежнему показывает своё.

OrderOptionValue _value(
  String id,
  String title, {
  int sort = 0,
  bool active = true,
}) =>
    OrderOptionValue(id: id, title: title, sortOrder: sort, isActive: active);

OrderOptionDef _select(
  String id,
  String title, {
  int sort = 0,
  bool active = true,
  List<OrderOptionValue> values = const <OrderOptionValue>[],
}) =>
    OrderOptionDef(
      id: id,
      productTypeId: 'pt',
      title: title,
      kind: kOrderOptionKindSelect,
      sortOrder: sort,
      isActive: active,
      values: values,
    );

OrderOptionDef _boolean(
  String id,
  String title, {
  int sort = 0,
  bool active = true,
}) =>
    OrderOptionDef(
      id: id,
      productTypeId: 'pt',
      title: title,
      kind: kOrderOptionKindBoolean,
      sortOrder: sort,
      isActive: active,
    );

OrderOptionSelection _picked(
  String optionId,
  String title,
  String valueId,
  String valueLabel, {
  String kind = kOrderOptionKindSelect,
  int sort = 0,
}) =>
    OrderOptionSelection(
      optionId: optionId,
      title: title,
      kind: kind,
      valueId: valueId,
      valueLabel: valueLabel,
      sortOrder: sort,
    );

void main() {
  group('decodeOrderExtraOptions', () {
    test('разбирает снимок и выстраивает его в порядке техлида', () {
      final rows = decodeOrderExtraOptions([
        {
          'option_id': 'handle',
          'title': 'Тип ручки',
          'kind': 'select',
          'value_id': 'v1',
          'value_label': 'Верёвочная',
          'sort': 20,
        },
        {
          'option_id': 'lam',
          'title': 'Ламинация',
          'kind': 'boolean',
          'value_id': 'yes',
          'value_label': 'Да',
          'sort': 10,
        },
      ]);

      expect(rows.map((r) => r.title), ['Ламинация', 'Тип ручки']);
      expect(rows.first.isBoolean, isTrue);
      expect(rows.last.valueLabel, 'Верёвочная');
    });

    test('принимает снимок строкой — так он приходит из кэша и экспорта', () {
      final raw = jsonEncode([
        {
          'option_id': 'lam',
          'title': 'Ламинация',
          'kind': 'boolean',
          'value_id': 'no',
          'value_label': 'Нет',
        },
      ]);

      expect(decodeOrderExtraOptions(raw).single.valueLabel, 'Нет');
    });

    test('отбрасывает битые записи, но соседние сохраняет', () {
      final rows = decodeOrderExtraOptions([
        {'option_id': 'lam', 'title': 'Ламинация'}, // без значения
        {'value_id': 'v1', 'value_label': 'Верёвочная'}, // без опции
        'мусор',
        {
          'option_id': 'glue',
          'title': 'Вид клея',
          'kind': 'select',
          'value_id': 'v9',
          'value_label': 'Горячий',
        },
      ]);

      // Проверка кусается: список не пуст, значит отбор сработал именно на
      // битых записях, а не на разборе целиком.
      expect(rows.map((r) => r.optionId), ['glue']);
    });

    test('на пустом и неожиданном входе даёт пустой список', () {
      expect(decodeOrderExtraOptions(null), isEmpty);
      expect(decodeOrderExtraOptions(''), isEmpty);
      expect(decodeOrderExtraOptions(42), isEmpty);
      expect(decodeOrderExtraOptions('{"не":"список"}'), isEmpty);
    });

    test('переживает круг записи и чтения', () {
      final original = [
        _picked('lam', 'Ламинация', kOrderOptionYes, 'Да',
            kind: kOrderOptionKindBoolean, sort: 10),
        _picked('handle', 'Тип ручки', 'v1', 'Верёвочная', sort: 20),
      ];

      expect(
        decodeOrderExtraOptions(encodeOrderExtraOptions(original)),
        original,
      );
    });
  });

  group('buildOrderExtraOptionRows', () {
    test('строит действующие опции в порядке техлида и подставляет выбор', () {
      final rows = buildOrderExtraOptionRows(
        defs: [
          _select('handle', 'Тип ручки', sort: 20, values: [
            _value('v1', 'Верёвочная', sort: 10),
            _value('v2', 'Плоская', sort: 20),
          ]),
          _boolean('lam', 'Ламинация', sort: 10),
        ],
        saved: [
          _picked('handle', 'Тип ручки', 'v1', 'Верёвочная', sort: 20),
        ],
      );

      expect(rows.map((r) => r.title), ['Ламинация', 'Тип ручки']);
      expect(rows.first.selection, isNull, reason: 'заполнять необязательно');
      expect(rows.last.valueLabel, 'Верёвочная');
      expect(rows.last.choices.map((c) => c.title), ['Верёвочная', 'Плоская']);
      expect(rows.every((r) => r.isRetired), isFalse);
    });

    test('опция, заведённая после заказа, появляется пустой строкой', () {
      final rows = buildOrderExtraOptionRows(
        defs: [_boolean('perf', 'Перфорация')],
        saved: const <OrderOptionSelection>[],
      );

      expect(rows.single.title, 'Перфорация');
      expect(rows.single.selection, isNull);
    });

    test('снятая с учёта опция остаётся, пока в заказе есть её значение', () {
      final retiredDef = _boolean('lam', 'Ламинация', active: false);
      final saved = [
        _picked('lam', 'Ламинация', kOrderOptionYes, 'Да',
            kind: kOrderOptionKindBoolean),
      ];

      final withValue =
          buildOrderExtraOptionRows(defs: [retiredDef], saved: saved);
      expect(withValue.single.valueLabel, 'Да');
      expect(withValue.single.isRetired, isTrue);

      // Кусается: та же снятая опция без значения в форме не появляется —
      // значит первая проверка держится на снимке, а не на самой строке
      // справочника.
      final withoutValue = buildOrderExtraOptionRows(
        defs: [retiredDef],
        saved: const <OrderOptionSelection>[],
      );
      expect(withoutValue, isEmpty);
    });

    test('список без вариантов не показывается, пока в заказе пусто', () {
      final empty = _select('glue', 'Вид клея', values: const []);

      expect(
        buildOrderExtraOptionRows(
          defs: [empty],
          saved: const <OrderOptionSelection>[],
        ),
        isEmpty,
        reason: 'выбирать нечего — строка была бы пустым списком',
      );

      // Кусается: с сохранённым значением та же опция строку даёт — иначе
      // пересохранение заказа потеряло бы выбранное.
      final withValue = buildOrderExtraOptionRows(
        defs: [empty],
        saved: [_picked('glue', 'Вид клея', 'v7', 'Горячий')],
      );
      expect(withValue.single.valueLabel, 'Горячий');

      // И кусается второй раз: один действующий вариант возвращает строку.
      final filled = buildOrderExtraOptionRows(
        defs: [
          _select('glue', 'Вид клея', values: [_value('v7', 'Горячий')]),
        ],
        saved: const <OrderOptionSelection>[],
      );
      expect(filled.single.choices.single.title, 'Горячий');
    });

    test('снятые строки уходят под действующие', () {
      final rows = buildOrderExtraOptionRows(
        defs: [_boolean('perf', 'Перфорация', sort: 99)],
        saved: [
          _picked('lam', 'Ламинация', kOrderOptionYes, 'Да',
              kind: kOrderOptionKindBoolean, sort: 1),
        ],
      );

      expect(rows.map((r) => r.title), ['Перфорация', 'Ламинация']);
      expect(rows.map((r) => r.isRetired), [false, true]);
    });

    test('выбранный вариант подставляется в список, даже если снят с учёта',
        () {
      final def = _select('handle', 'Тип ручки', values: [
        _value('v1', 'Верёвочная', sort: 10, active: false),
        _value('v2', 'Плоская', sort: 20),
      ]);

      final chosen = buildOrderExtraOptionRows(
        defs: [def],
        saved: [_picked('handle', 'Тип ручки', 'v1', 'Верёвочная')],
      );
      expect(
        chosen.single.choices.map((c) => c.id),
        containsAll(<String>['v1', 'v2']),
        reason: 'иначе выпадающий список потеряет своё значение',
      );

      // Кусается: без выбора снятый вариант в список не попадает.
      final untouched = buildOrderExtraOptionRows(
        defs: [def],
        saved: const <OrderOptionSelection>[],
      );
      expect(untouched.single.choices.map((c) => c.id), ['v2']);
    });

    test('вариант, удалённый насовсем, восстанавливается из снимка', () {
      final rows = buildOrderExtraOptionRows(
        defs: [
          _select('handle', 'Тип ручки', values: [_value('v2', 'Плоская')]),
        ],
        saved: [_picked('handle', 'Тип ручки', 'gone', 'Крученая')],
      );

      expect(rows.single.valueLabel, 'Крученая');
      expect(
        rows.single.choices.where((c) => c.id == 'gone').single.title,
        'Крученая',
      );
    });

    test('переименование варианта не трогает сохранённое значение', () {
      final rows = buildOrderExtraOptionRows(
        defs: [
          _select('handle', 'Тип ручки', values: [
            _value('v1', 'Верёвочная ручка'), // переименовали
          ]),
        ],
        saved: [_picked('handle', 'Тип ручки', 'v1', 'Верёвочная')],
      );

      expect(rows.single.valueLabel, 'Верёвочная',
          reason: 'снимок заказа переписывать нельзя');
      expect(rows.single.choices.single.title, 'Верёвочная ручка',
          reason: 'а выбирать предлагаем уже новым названием');
    });
  });

  group('withChoice', () {
    OrderExtraOptionRow booleanRow() => buildOrderExtraOptionRows(
          defs: [_boolean('lam', 'Ламинация')],
          saved: const <OrderOptionSelection>[],
        ).single;

    OrderExtraOptionRow selectRow() => buildOrderExtraOptionRows(
          defs: [
            _select('handle', 'Тип ручки', values: [_value('v1', 'Верёвочная')]),
          ],
          saved: const <OrderOptionSelection>[],
        ).single;

    test('Да/Нет получает свою подпись', () {
      expect(booleanRow().withChoice(kOrderOptionYes).valueLabel, 'Да');
      expect(booleanRow().withChoice(kOrderOptionNo).valueLabel, 'Нет');
    });

    test('подпись выбранного варианта берётся из справочника', () {
      expect(selectRow().withChoice('v1').valueLabel, 'Верёвочная');
    });

    test('пустой выбор снимает значение', () {
      final chosen = selectRow().withChoice('v1');
      expect(chosen.selection, isNotNull);
      expect(chosen.withChoice(null).selection, isNull);
      expect(chosen.withChoice('  ').selection, isNull);
    });

    test('неизвестный код снимает выбор, а не оставляет прежний', () {
      final chosen = selectRow().withChoice('v1');
      expect(chosen.withChoice('нет такого').selection, isNull);
      expect(booleanRow().withChoice('maybe').selection, isNull);
    });
  });

  group('selectionsFromRows', () {
    test('незаполненные опции в заказ не пишутся', () {
      final rows = buildOrderExtraOptionRows(
        defs: [_boolean('lam', 'Ламинация'), _boolean('perf', 'Перфорация')],
        saved: const <OrderOptionSelection>[],
      );

      final filled = [rows.first.withChoice(kOrderOptionYes), rows.last];

      expect(selectionsFromRows(filled).map((s) => s.optionId), ['lam']);
    });

    test('пересохранение подтягивает переименования справочника', () {
      final rows = buildOrderExtraOptionRows(
        defs: [
          _select('handle', 'Тип ручки изделия', values: [
            _value('v1', 'Верёвочная ручка'),
          ]),
        ],
        saved: [_picked('handle', 'Тип ручки', 'v1', 'Верёвочная')],
      );

      final saved = selectionsFromRows(rows).single;
      expect(saved.title, 'Тип ручки изделия');
      expect(saved.valueLabel, 'Верёвочная ручка',
          reason: 'в форме менеджер видел именно это название');
      expect(saved.valueId, 'v1', reason: 'а значение то же самое');
    });

    test('снятые с учёта строки переносятся снимком, без справочника', () {
      final rows = buildOrderExtraOptionRows(
        defs: const <OrderOptionDef>[],
        saved: [_picked('glue', 'Вид клея', 'v7', 'Горячий', sort: 5)],
      );

      expect(rows.single.isRetired, isTrue);
      expect(selectionsFromRows(rows).single,
          _picked('glue', 'Вид клея', 'v7', 'Горячий', sort: 5));
    });

    test('удалённый вариант сохраняет старую подпись при пересохранении', () {
      final rows = buildOrderExtraOptionRows(
        defs: [_select('handle', 'Тип ручки', values: const [])],
        saved: [_picked('handle', 'Тип ручки', 'gone', 'Крученая')],
      );

      expect(selectionsFromRows(rows).single.valueLabel, 'Крученая');
    });
  });

  group('describeOrderExtraOptionChanges', () {
    final lamYes = _picked('lam', 'Ламинация', kOrderOptionYes, 'Да',
        kind: kOrderOptionKindBoolean, sort: 10);
    final lamNo = _picked('lam', 'Ламинация', kOrderOptionNo, 'Нет',
        kind: kOrderOptionKindBoolean, sort: 10);
    final handle = _picked('handle', 'Тип ручки', 'v1', 'Верёвочная', sort: 20);

    test('без изменений возвращает null', () {
      expect(
        describeOrderExtraOptionChanges(before: [lamYes], after: [lamYes]),
        isNull,
      );
    });

    test('описывает смену значения', () {
      expect(
        describeOrderExtraOptionChanges(before: [lamYes], after: [lamNo]),
        'Ламинация: Да → Нет',
      );
    });

    test('описывает появление и снятие значения', () {
      expect(
        describeOrderExtraOptionChanges(
            before: const <OrderOptionSelection>[], after: [handle]),
        'Тип ручки: — → Верёвочная',
      );
      expect(
        describeOrderExtraOptionChanges(
            before: [handle], after: const <OrderOptionSelection>[]),
        'Тип ручки: Верёвочная → —',
      );
    });

    test('перечисляет несколько изменений в порядке блока', () {
      expect(
        describeOrderExtraOptionChanges(
          before: [handle],
          after: [lamYes],
        ),
        'Ламинация: — → Да; Тип ручки: Верёвочная → —',
      );
    });

    test('переименование опции само по себе изменением не считается', () {
      final renamed = _picked('lam', 'Ламинирование', kOrderOptionYes, 'Да',
          kind: kOrderOptionKindBoolean, sort: 10);

      expect(
        describeOrderExtraOptionChanges(before: [lamYes], after: [renamed]),
        isNull,
        reason: 'в журнале заказа это шум: значение осталось прежним',
      );
    });
  });

  /// Разница между «опций не выбрано» и «про опции ничего не знаем».
  ///
  /// Тот же класс дефекта, что закрывает order_product_type_id_payload_test:
  /// `updateOrder` пишет `toMap(includeNulls: true)`, и заказ, собранный в
  /// коде из отдельных полей (правка бумаги из рабочего пространства), послал
  /// бы пустой массив и стёр бы выбранные опции.
  group('OrderModel ↔ extra_options', () {
    OrderModel buildOrder({List<OrderOptionSelection>? extraOptions}) =>
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
            width: 100,
            height: 200,
            depth: 50,
          ),
          extraOptions: extraOptions,
        );

    final lamination = _picked('lam', 'Ламинация', kOrderOptionYes, 'Да',
        kind: kOrderOptionKindBoolean, sort: 10);

    test('про опции не знаем: ключа нет в payload даже с includeNulls', () {
      expect(buildOrder().toMap().containsKey('extra_options'), isFalse);
      expect(
        buildOrder().toMap(includeNulls: true).containsKey('extra_options'),
        isFalse,
        reason: 'именно так пишет updateOrder — иначе сейв стирал бы опции',
      );

      // Кусается: с известным списком ключ на месте, то есть проверка выше
      // держится на null, а не на том, что ключа не бывает вовсе.
      expect(
        buildOrder(extraOptions: [lamination])
            .toMap(includeNulls: true)['extra_options'],
        isA<List<dynamic>>(),
      );
    });

    test('опций не выбрано — это утверждение, оно уходит пустым массивом', () {
      final payload =
          buildOrder(extraOptions: const <OrderOptionSelection>[]).toMap();

      expect(payload['extra_options'], isEmpty);
      expect(payload.containsKey('extra_options'), isTrue);
    });

    test('снимок переживает запись и чтение', () {
      final payload = buildOrder(extraOptions: [lamination]).toMap();
      final restored = OrderModel.fromMap(payload);

      expect(restored.extraOptions, [lamination]);
    });

    test('строка без колонки читается как «не знаем», с колонкой — как есть',
        () {
      final withoutColumn = OrderModel.fromMap(<String, dynamic>{
        'id': 'order-1',
        'customer': 'Заказчик',
        'order_date': DateTime.utc(2026, 9, 10).toIso8601String(),
        'product': <String, dynamic>{'type': 'П-пакет'},
      });
      expect(withoutColumn.extraOptions, isNull);

      final empty = OrderModel.fromMap(<String, dynamic>{
        'id': 'order-1',
        'customer': 'Заказчик',
        'order_date': DateTime.utc(2026, 9, 10).toIso8601String(),
        'product': <String, dynamic>{'type': 'П-пакет'},
        'extra_options': const <dynamic>[],
      });
      expect(empty.extraOptions, isEmpty);
    });

    test('copyWith сохраняет и подменяет снимок', () {
      final order = buildOrder(extraOptions: [lamination]);

      expect(order.copyWith(customer: 'Другой').extraOptions, [lamination]);
      expect(
        order.copyWith(extraOptions: const <OrderOptionSelection>[])
            .extraOptions,
        isEmpty,
      );
      expect(buildOrder().copyWith(customer: 'Другой').extraOptions, isNull);
    });
  });
}
