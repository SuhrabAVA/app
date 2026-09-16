import 'package:flutter_test/flutter_test.dart';
import 'package:sheet_clone/modules/orders/order_model.dart';
import 'package:sheet_clone/modules/orders/product_model.dart';
import 'package:sheet_clone/modules/production/workplace_history.dart';
import 'package:sheet_clone/modules/tasks/task_model.dart';

void main() {
  OrderModel order(String id) => OrderModel(
        id: id,
        manager: 'manager',
        customer: 'Заказчик $id',
        orderDate: DateTime(2026, 8, 1),
        dueDate: null,
        product: ProductModel(
          id: 'p-$id',
          type: 'Пакет',
          quantity: 100,
          width: 10,
          height: 20,
          depth: 5,
        ),
      );

  TaskModel task({
    required String orderId,
    required String stageId,
    TaskStatus status = TaskStatus.completed,
    int? completedAt,
    List<TaskComment> comments = const [],
    String? capturedByWorkplaceId,
  }) {
    return TaskModel(
      id: '$orderId-$stageId',
      orderId: orderId,
      stageId: stageId,
      status: status,
      completedAt: completedAt,
      comments: comments,
      capturedByWorkplaceId: capturedByWorkplaceId,
    );
  }

  TaskComment comment(int timestamp) => TaskComment(
        id: '$timestamp',
        type: 'quantity',
        text: 'Сделано',
        userId: 'u1',
        timestamp: timestamp,
      );

  test('лента рабочего места: новые сверху', () {
    final entries = workplaceHistory(
      workplaceId: 'print',
      orders: [order('a'), order('b'), order('c')],
      tasks: [
        task(orderId: 'a', stageId: 'print', completedAt: 100),
        task(orderId: 'b', stageId: 'print', completedAt: 300),
        task(orderId: 'c', stageId: 'print', completedAt: 200),
      ],
    );

    expect(entries.map((e) => e.order.id), ['b', 'c', 'a']);
  });

  test('чужие рабочие места и незакрытые этапы в ленту не попадают', () {
    final entries = workplaceHistory(
      workplaceId: 'print',
      orders: [order('a'), order('b'), order('c')],
      tasks: [
        task(orderId: 'a', stageId: 'pack', completedAt: 500),
        task(
          orderId: 'b',
          stageId: 'print',
          status: TaskStatus.inProgress,
          completedAt: 400,
        ),
        task(orderId: 'c', stageId: 'print', completedAt: 300),
      ],
    );

    expect(entries.map((e) => e.order.id), ['c']);
  });

  test('заказ попадает в ленту и когда этап захвачен рабочим местом', () {
    final entries = workplaceHistory(
      workplaceId: 'auto-big',
      orders: [order('a')],
      tasks: [
        task(
          orderId: 'a',
          stageId: 'p_main_switch',
          capturedByWorkplaceId: 'auto-big',
          completedAt: 100,
        ),
      ],
    );

    expect(entries.map((e) => e.order.id), ['a']);
  });

  test('без completed_at время берётся из последнего комментария', () {
    // Задачи, закрытые до появления колонки, отметки времени не имеют, но
    // выпадать из истории не должны.
    final entries = workplaceHistory(
      workplaceId: 'print',
      orders: [order('a'), order('b')],
      tasks: [
        task(
          orderId: 'a',
          stageId: 'print',
          comments: [comment(100), comment(900)],
        ),
        task(orderId: 'b', stageId: 'print', completedAt: 500),
      ],
    );

    expect(entries.map((e) => e.order.id), ['a', 'b']);
    expect(entries.first.doneAt, 900);
  });

  test('ни отметки, ни комментариев — заказ в конце ленты, но не пропадает', () {
    final entries = workplaceHistory(
      workplaceId: 'print',
      orders: [order('a'), order('b')],
      tasks: [
        task(orderId: 'a', stageId: 'print'),
        task(orderId: 'b', stageId: 'print', completedAt: 5),
      ],
    );

    expect(entries.map((e) => e.order.id), ['b', 'a']);
  });

  test('лента не длиннее лимита', () {
    final orders = [for (var i = 0; i < 25; i++) order('o$i')];
    final tasks = [
      for (var i = 0; i < 25; i++)
        task(orderId: 'o$i', stageId: 'print', completedAt: i + 1),
    ];

    final entries = workplaceHistory(
      workplaceId: 'print',
      orders: orders,
      tasks: tasks,
    );

    expect(entries, hasLength(kWorkplaceHistoryLimit));
    expect(entries.first.order.id, 'o24');
    expect(entries.last.order.id, 'o15');
  });

  test('лента «Все»: только полностью пройденные заказы', () {
    final entries = completedOrdersHistory(
      orders: [order('done'), order('partial')],
      tasks: [
        task(orderId: 'done', stageId: 'print', completedAt: 100),
        task(orderId: 'done', stageId: 'pack', completedAt: 200),
        task(orderId: 'partial', stageId: 'print', completedAt: 300),
        task(
          orderId: 'partial',
          stageId: 'pack',
          status: TaskStatus.waiting,
        ),
      ],
    );

    expect(entries.map((e) => e.order.id), ['done']);
    expect(entries.first.doneAt, 200);
  });
}
