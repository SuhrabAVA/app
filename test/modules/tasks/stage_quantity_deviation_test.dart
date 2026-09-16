import 'package:flutter_test/flutter_test.dart';
import 'package:sheet_clone/modules/orders/order_model.dart';
import 'package:sheet_clone/modules/orders/product_model.dart';
import 'package:sheet_clone/modules/tasks/quantity_status_service.dart';
import 'package:sheet_clone/modules/tasks/stage_quantity_deviation.dart';
import 'package:sheet_clone/modules/tasks/task_model.dart';

int _seq = 0;

OrderModel _order({required int runSize}) => OrderModel(
      id: 'o1',
      manager: 'm',
      customer: 'Донер на Сатпаева',
      orderDate: DateTime(2026, 7, 17),
      dueDate: null,
      product: ProductModel(
        id: 'p',
        type: 'П-образный пакет',
        quantity: runSize,
        width: 34,
        height: 35,
        depth: 10,
      ),
    );

TaskComment _comment(String type, String userId, String text) => TaskComment(
      id: 'c${_seq++}',
      type: type,
      text: text,
      userId: userId,
      timestamp: 1750000000000 + _seq,
    );

TaskModel _task(List<TaskComment> comments) => TaskModel(
      id: 't${_seq++}',
      orderId: 'o1',
      stageId: 'stage',
      status: TaskStatus.completed,
      assignees: const ['a'],
      comments: comments,
    );

void main() {
  group('границы отклонения количества', () {
    test('точно в план — норма', () {
      expect(
        getQuantityStatus(actual: 1000, expected: 1000),
        QuantityStatus.success,
      );
    });

    test('в пределах 2 % — норма, в обе стороны', () {
      // Прежнее правило красило зелёным только точное совпадение, и зелёного
      // не видел никто: в план ровно не выходит почти ни один этап.
      expect(
        getQuantityStatus(actual: 1020, expected: 1000),
        QuantityStatus.success,
      );
      expect(
        getQuantityStatus(actual: 980, expected: 1000),
        QuantityStatus.success,
      );
    });

    test('от 2 % до 10 % — предупреждение, в обе стороны', () {
      expect(
        getQuantityStatus(actual: 1021, expected: 1000),
        QuantityStatus.warning,
      );
      expect(
        getQuantityStatus(actual: 900, expected: 1000),
        QuantityStatus.warning,
      );
    });

    test('дальше 10 % — тревога, в обе стороны', () {
      expect(
        getQuantityStatus(actual: 1101, expected: 1000),
        QuantityStatus.danger,
      );
      expect(
        getQuantityStatus(actual: 899, expected: 1000),
        QuantityStatus.danger,
      );
    });

    test('плана нет — сравнивать не с чем', () {
      expect(
        getQuantityStatus(actual: 1000, expected: null),
        QuantityStatus.unknown,
      );
      expect(quantityDeviation(actual: 1000, expected: 0), isNull);
    });
  });

  group('сверка этапа с планом заказа', () {
    test('тираж сошёлся — проблемы нет', () {
      final check = checkStageQuantity(
        order: _order(runSize: 1000),
        stageTasks: [
          _task([_comment('quantity_done', 'a', '1000')])
        ],
        unit: 'шт',
      );
      expect(check, isNotNull);
      expect(check!.status, QuantityStatus.success);
      expect(check.isProblem, isFalse);
    });

    test('недодали больше 10 % — тревога с подписью', () {
      final check = checkStageQuantity(
        order: _order(runSize: 50000),
        stageTasks: [
          _task([_comment('quantity_done', 'a', '24150')])
        ],
        unit: 'шт',
      );
      expect(check!.status, QuantityStatus.danger);
      expect(check.isProblem, isTrue);
      expect(check.isOver, isFalse);
      expect(check.signedPercentLabel, startsWith('−'));
    });

    test('передали — знак плюс', () {
      final check = checkStageQuantity(
        order: _order(runSize: 1000),
        stageTasks: [
          _task([_comment('quantity_done', 'a', '1050')])
        ],
        unit: 'шт',
      );
      expect(check!.status, QuantityStatus.warning);
      expect(check.isOver, isTrue);
      expect(check.signedPercentLabel, '+5 %');
    });

    test('количество не вводили — сверять нечего', () {
      final check = checkStageQuantity(
        order: _order(runSize: 1000),
        stageTasks: [
          _task([_comment('start', 'a', '')])
        ],
        unit: 'шт',
      );
      expect(check, isNull);
    });

    test('нет заказа или задач — молчим, а не выдаём ноль', () {
      expect(
        checkStageQuantity(order: null, stageTasks: const [], unit: 'шт'),
        isNull,
      );
      expect(
        checkStageQuantity(
          order: _order(runSize: 1000),
          stageTasks: const [],
          unit: 'шт',
        ),
        isNull,
      );
    });

    test('тираж не задан — плана нет', () {
      final check = checkStageQuantity(
        order: _order(runSize: 0),
        stageTasks: [
          _task([_comment('quantity_done', 'a', '500')])
        ],
        unit: 'шт',
      );
      expect(check, isNull);
    });
  });
}
