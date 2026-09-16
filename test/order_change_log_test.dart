import 'package:flutter_test/flutter_test.dart';
import 'package:sheet_clone/modules/orders/material_model.dart';
import 'package:sheet_clone/modules/orders/order_change_log.dart';
import 'package:sheet_clone/modules/orders/order_model.dart';
import 'package:sheet_clone/modules/orders/product_model.dart';

/// История заказа обязана отвечать на вопрос «кто и что поменял».
///
/// До этого на каждое сохранение писалась одна строка «Изменён заказ» — по ней
/// нельзя было установить ни поле, ни прежнее значение.

OrderModel _order({
  String customer = 'Дареджани',
  String manager = 'Расул',
  int quantity = 1000,
  double width = 30,
  double height = 20,
  double depth = 10,
  String cardboard = 'нет',
  String handle = '-',
  double makeready = 0,
  double val = 0,
  String comments = '',
  String status = 'draft',
  DateTime? dueDate,
  List<String> params = const <String>[],
  List<MaterialModel> papers = const <MaterialModel>[],
  int? formNo,
  String? formSeries,
}) =>
    OrderModel(
      id: 'order-1',
      manager: manager,
      customer: customer,
      orderDate: DateTime(2026, 9, 10),
      dueDate: dueDate,
      status: status,
      comments: comments,
      cardboard: cardboard,
      handle: handle,
      makeready: makeready,
      val: val,
      additionalParams: params,
      paperMaterials: papers,
      newFormNo: formNo,
      formSeries: formSeries,
      product: ProductModel(
        id: 'p',
        type: 'П-пакет',
        quantity: quantity,
        width: width,
        height: height,
        depth: depth,
      ),
    );

void main() {
  group('diffOrderFields', () {
    test('одинаковые заказы не дают изменений', () {
      expect(diffOrderFields(before: _order(), after: _order()), isEmpty);
    });

    test('изменённое поле названо словами: было → стало', () {
      final changes = diffOrderFields(
        before: _order(quantity: 1000),
        after: _order(quantity: 2000),
      );

      expect(changes, hasLength(1));
      expect(changes.single.label, 'Тираж');
      expect(changes.single.before, '1000');
      expect(changes.single.after, '2000');
      expect(changes.single.line, 'Тираж: 1000 → 2000');
    });

    test('незаполненное поле читается как «не указано»', () {
      final changes = diffOrderFields(
        before: _order(),
        after: _order(dueDate: DateTime(2026, 9, 17)),
      );

      expect(changes.single.line, 'Срок: не указано → 17.09.2026');
      expect(changes.single.isFilling, isTrue);
    });

    test('«нет» и «-» значением не считаются', () {
      // Иначе при первом же выборе картона в историю падало бы
      // «Картон: нет → есть», а при снятии — «есть → нет»: слово «нет» в форме
      // означает пустое поле, а не значение.
      expect(
        diffOrderFields(
          before: _order(cardboard: 'нет', handle: '-'),
          after: _order(cardboard: 'нет', handle: '-'),
        ),
        isEmpty,
      );

      final changes = diffOrderFields(
        before: _order(cardboard: 'нет'),
        after: _order(cardboard: 'есть'),
      );
      expect(changes.single.line, 'Картон: не указано → есть');
    });

    test('несколько правок перечисляются в порядке формы', () {
      final changes = diffOrderFields(
        before: _order(),
        after: _order(
          customer: 'iqos',
          quantity: 5000,
          comments: 'срочно',
        ),
      );

      expect(
        changes.map((c) => c.label),
        ['Заказчик', 'Тираж', 'Комментарий'],
      );
    });

    test('смена бумаги видна по названию', () {
      final changes = diffOrderFields(
        before: _order(papers: [MaterialModel(name: 'Крафт 90', quantity: 100)]),
        after: _order(
          papers: [
            MaterialModel(name: 'Мелованная', grammage: '120', quantity: 100),
          ],
        ),
      );

      expect(changes.single.label, 'Основная бумага');
      expect(changes.single.before, 'Крафт 90');
      expect(changes.single.after, 'Мелованная (120 гр)');
    });

    test('подрезка попадает в историю, а статус — нет', () {
      final changes = diffOrderFields(
        before: _order(),
        after: _order(params: ['Подрезка'], status: 'ready_to_start'),
      );

      expect(changes.map((c) => c.line), ['Подрезка: не указано → да']);
      // Кусается: статус меняет пересчёт обеспеченности, а не сотрудник, и в
      // истории он выглядел бы правкой человека, которой не было.
      expect(
        changes.map((c) => c.label),
        isNot(contains('Статус')),
      );
    });

    test('печатная форма собирается из серии и номера', () {
      final changes = diffOrderFields(
        before: _order(),
        after: _order(formSeries: 'А', formNo: 458),
      );

      expect(changes.single.line, 'Печатная форма: не указано → А 458');
    });
  });

  group('describeOrderFieldChanges', () {
    test('без изменений записи нет', () {
      // Кусается: пустой список — это «не писать событие вовсе», а не пустая
      // строка. Раньше «Изменён заказ» падал в историю на каждом сохранении.
      expect(describeOrderFieldChanges(const []), isNull);
    });

    test('каждая правка — своей строкой', () {
      final text = describeOrderFieldChanges(
        diffOrderFields(
          before: _order(),
          after: _order(customer: 'iqos', quantity: 5000),
        ),
      );

      expect(text, 'Заказчик: Дареджани → iqos\nТираж: 1000 → 5000');
    });
  });

  group('describeOrderCreation', () {
    test('перечисляет заполненное, а не все поля подряд', () {
      final text = describeOrderCreation(_order(
        quantity: 10000,
        papers: [MaterialModel(name: 'Крафт 90', quantity: 500)],
        dueDate: DateTime(2026, 9, 20),
      ));

      expect(text, contains('Заказчик: Дареджани'));
      expect(text, contains('Тираж: 10000'));
      expect(text, contains('Бумага: Крафт 90'));
      expect(text, contains('Срок: 20.09.2026'));
      // Кусается: незаполненное в список не лезет.
      expect(text, isNot(contains('Приладка')));
      expect(text, isNot(contains('Комментарий')));
    });

    test('пустой заказ не даёт пустой записи', () {
      final text = describeOrderCreation(OrderModel(
        id: 'x',
        manager: '',
        customer: '',
        orderDate: DateTime(2026, 9, 10),
        dueDate: null,
        product: ProductModel(
          id: 'p',
          type: '',
          quantity: 0,
          width: 0,
          height: 0,
          depth: 0,
        ),
      ));

      expect(text, 'Заказ создан');
    });
  });
}
