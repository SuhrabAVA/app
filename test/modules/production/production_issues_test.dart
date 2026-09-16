import 'package:flutter_test/flutter_test.dart';
import 'package:sheet_clone/modules/orders/material_model.dart';
import 'package:sheet_clone/modules/orders/order_model.dart';
import 'package:sheet_clone/modules/orders/product_model.dart';
import 'package:sheet_clone/modules/production/production_issues.dart';
import 'package:sheet_clone/modules/tasks/task_model.dart';

int _seq = 0;

OrderModel _order({
  String id = 'o1',
  String customer = 'Донер на Сатпаева',
  int runSize = 1000,
  String status = 'in_production',
  bool shortage = false,
  String shortageMessage = '',
  bool withPaper = true,
  DateTime? shippedAt,
  DateTime? dueDate,
  DateTime? completedAt,
}) =>
    OrderModel(
      id: id,
      manager: 'm',
      customer: customer,
      orderDate: DateTime(2026, 7, 17),
      dueDate: dueDate,
      completedAt: completedAt,
      status: status,
      shippedAt: shippedAt,
      hasMaterialShortage: shortage,
      materialShortageMessage: shortageMessage,
      // Незаполненная строка бумаги приходит с пустым именем — именно так
      // выглядит «материал не выбран» в боевых данных.
      paperMaterials: [
        MaterialModel(name: withPaper ? 'Крафт 90' : ''),
      ],
      product: ProductModel(
        id: 'p',
        type: 'П-образный пакет',
        quantity: runSize,
        width: 34,
        height: 35,
        depth: 10,
      ),
    );

TaskComment _c(String type, String userId, String text, {int at = 0}) =>
    TaskComment(
      id: 'c${_seq++}',
      type: type,
      text: text,
      userId: userId,
      timestamp: at == 0 ? 1750000000000 + _seq : at,
    );

TaskModel _task({
  required TaskStatus status,
  List<TaskComment> comments = const [],
  String orderId = 'o1',
  String stageId = 'stage-1',
}) =>
    TaskModel(
      id: 't${_seq++}',
      orderId: orderId,
      stageId: stageId,
      stageGroupKey: stageId,
      status: status,
      assignees: const ['a'],
      comments: comments,
    );

StageMeta _meta(String stageId) =>
    const StageMeta(name: 'Автомат большой', unit: 'шт');

void main() {
  group('количество на завершённом этапе', () {
    test('расхождение больше 10 % — срочно', () {
      final issues = collectProductionIssues(
        orders: [_order(runSize: 50000)],
        tasks: [
          _task(
            status: TaskStatus.completed,
            comments: [
              _c('user_done', 'a', 'done'),
              _c('quantity_done', 'a', '24150'),
            ],
          ),
        ],
        stageMeta: _meta,
      );

      final quantity = issues
          .where((i) => i.kind == ProductionIssueKind.quantity)
          .toList();
      expect(quantity, hasLength(1));
      expect(quantity.single.severity, IssueSeverity.danger);
      expect(quantity.single.stageName, 'Автомат большой');
      expect(quantity.single.title, contains('Недодали'));
      expect(quantity.single.detail, contains('24150'));
    });

    test('расхождение от 2 до 10 % — внимание', () {
      final issues = collectProductionIssues(
        orders: [_order(runSize: 1000)],
        tasks: [
          _task(
            status: TaskStatus.completed,
            comments: [
              _c('user_done', 'a', 'done'),
              _c('quantity_done', 'a', '1050'),
            ],
          ),
        ],
        stageMeta: _meta,
      );
      final quantity =
          issues.where((i) => i.kind == ProductionIssueKind.quantity);
      expect(quantity.single.severity, IssueSeverity.warning);
      expect(quantity.single.title, contains('Передали'));
    });

    test('в пределах 2 % — в список не попадает', () {
      final issues = collectProductionIssues(
        orders: [_order(runSize: 1000)],
        tasks: [
          _task(
            status: TaskStatus.completed,
            comments: [
              _c('user_done', 'a', 'done'),
              _c('quantity_done', 'a', '1015'),
            ],
          ),
        ],
        stageMeta: _meta,
      );
      expect(
        issues.where((i) => i.kind == ProductionIssueKind.quantity),
        isEmpty,
      );
    });

    test('незавершённый этап не сверяется', () {
      // Пока этап идёт, сделано меньше плана по определению — точка горела бы
      // у каждого работающего этапа.
      final issues = collectProductionIssues(
        orders: [_order(runSize: 1000)],
        tasks: [
          _task(
            status: TaskStatus.inProgress,
            comments: [
              _c('start', 'a', 'Начал(а) этап'),
              _c('quantity_stage_total', 'a', '100'),
            ],
          ),
        ],
        stageMeta: _meta,
      );
      expect(
        issues.where((i) => i.kind == ProductionIssueKind.quantity),
        isEmpty,
      );
    });
  });

  group('проблема на этапе', () {
    test('текст проблемы попадает в заголовок', () {
      final issues = collectProductionIssues(
        orders: [_order()],
        tasks: [
          _task(
            status: TaskStatus.problem,
            comments: [
              _c('start', 'a', 'Начал(а) этап'),
              _c('problem', 'a', 'Расул попросил перезарядится'),
            ],
          ),
        ],
        stageMeta: _meta,
      );
      final problem = issues
          .where((i) => i.kind == ProductionIssueKind.stageProblem)
          .single;
      expect(problem.severity, IssueSeverity.danger);
      expect(problem.title, 'Расул попросил перезарядится');
      expect(problem.stageName, 'Автомат большой');
    });

    test('проблемный этап не дублируется строкой про количество', () {
      final issues = collectProductionIssues(
        orders: [_order(runSize: 50000)],
        tasks: [
          _task(
            status: TaskStatus.problem,
            comments: [
              _c('start', 'a', 'Начал(а) этап'),
              _c('quantity_done', 'a', '10'),
              _c('problem', 'a', 'Встал станок'),
            ],
          ),
        ],
        stageMeta: _meta,
      );
      expect(issues, hasLength(1));
      expect(issues.single.kind, ProductionIssueKind.stageProblem);
    });
  });

  group('материал', () {
    test('нехватка материала — срочно', () {
      final issues = collectProductionIssues(
        orders: [
          _order(shortage: true, shortageMessage: 'Не хватает 200 кг крафта'),
        ],
        tasks: const [],
        stageMeta: _meta,
      );
      final material =
          issues.where((i) => i.kind == ProductionIssueKind.material).single;
      expect(material.severity, IssueSeverity.danger);
      expect(material.detail, 'Не хватает 200 кг крафта');
      expect(material.stageName, isNull);
    });

    test('заказ ждёт материала — внимание', () {
      final issues = collectProductionIssues(
        orders: [_order(status: 'waiting_materials')],
        tasks: const [],
        stageMeta: _meta,
      );
      final material = issues
          .where((i) => i.title == 'Ожидает материала')
          .single;
      expect(material.severity, IssueSeverity.warning);
    });

    test('завершённый заказ про материал не спрашивают', () {
      final issues = collectProductionIssues(
        orders: [_order(status: 'completed', withPaper: false)],
        tasks: const [],
        stageMeta: _meta,
      );
      expect(issues, isEmpty);
    });
  });

  group('порядок и охват', () {
    test('срочное выше внимания', () {
      final issues = collectProductionIssues(
        orders: [
          _order(id: 'o1', customer: 'Жёлтый', status: 'waiting_materials'),
          _order(id: 'o2', customer: 'Красный', shortage: true),
        ],
        tasks: const [],
        stageMeta: _meta,
      );
      expect(issues.first.severity, IssueSeverity.danger);
      expect(issues.first.customer, 'Красный');
    });

    test('задачи чужих заказов игнорируются', () {
      final issues = collectProductionIssues(
        orders: [_order(id: 'o1', runSize: 1000)],
        tasks: [
          _task(
            orderId: 'other',
            status: TaskStatus.problem,
            comments: [_c('problem', 'a', 'Не наш заказ')],
          ),
        ],
        stageMeta: _meta,
      );
      expect(issues, isEmpty);
    });

    test('всё в порядке — список пуст', () {
      final issues = collectProductionIssues(
        orders: [_order(runSize: 1000)],
        tasks: [
          _task(
            status: TaskStatus.completed,
            comments: [
              _c('user_done', 'a', 'done'),
              _c('quantity_done', 'a', '1000'),
            ],
          ),
        ],
        stageMeta: _meta,
      );
      expect(issues, isEmpty);
    });
  });
  group('упаковка сравнивается в штуках', () {
    // Скриншот доски: «Алмадиева SULO · Упаковка · Недодали −99 % · 49 из 5000
    // пачка». На деле упаковали 1700 + 3178 = 4878 штук из 5000 — недобор 2 %,
    // то есть в норму. В список такой этап попадать не должен вовсе.
    String packRecord(num pieces, int packs) =>
        '{"actual":$pieces.0,"unit":"шт","expected":5000.0,'
        '"display":"$pieces шт · $packs уп","packs":$packs,"pack_size":100.0}';

    StageMeta packMeta(String stageId) =>
        const StageMeta(name: 'Упаковка', unit: 'пачка');

    test('4878 из 5000 штук — это недобор 2,4 %, а не −99 %', () {
      final issues = collectProductionIssues(
        orders: [_order(runSize: 5000)],
        tasks: [
          _task(
            status: TaskStatus.completed,
            comments: [
              _c('user_done', 'a', 'done'),
              _c('quantity_done', 'a', packRecord(1700, 17)),
              _c('quantity_done', 'b', packRecord(3178, 32)),
            ],
          ),
        ],
        stageMeta: packMeta,
      );
      final quantity =
          issues.where((i) => i.kind == ProductionIssueKind.quantity).single;
      // Раньше сравнивались упаковки с планом в штуках: «49 из 5000», красный
      // «недодали −99 %». Теперь обе стороны в штуках.
      expect(quantity.severity, IssueSeverity.warning);
      expect(quantity.detail, '4878 из 5000 шт');
      expect(quantity.title, 'Недодали −2.4 %');
    });

    test('настоящий недобор на упаковке виден и подписан в штуках', () {
      final issues = collectProductionIssues(
        orders: [_order(runSize: 5000)],
        tasks: [
          _task(
            status: TaskStatus.completed,
            comments: [
              _c('user_done', 'a', 'done'),
              _c('quantity_done', 'a', packRecord(1700, 17)),
            ],
          ),
        ],
        stageMeta: packMeta,
      );
      final quantity =
          issues.where((i) => i.kind == ProductionIssueKind.quantity).single;
      expect(quantity.severity, IssueSeverity.danger);
      expect(quantity.detail, '1700 из 5000 шт');
    });
  });
  group('отгруженные заказы', () {
    test('отгруженный заказ уходит из списка целиком', () {
      // Товар у заказчика: ни пересчитать тираж, ни довезти материал уже
      // нельзя — строка, по которой никто не примет решения.
      final issues = collectProductionIssues(
        orders: [
          _order(runSize: 50000, shortage: true, shippedAt: DateTime(2026, 9, 1)),
        ],
        tasks: [
          _task(
            status: TaskStatus.completed,
            comments: [
              _c('user_done', 'a', 'done'),
              _c('quantity_done', 'a', '24150'),
            ],
          ),
        ],
        stageMeta: _meta,
      );
      expect(issues, isEmpty);
    });

    test('неотгруженный с тем же расхождением остаётся', () {
      final issues = collectProductionIssues(
        orders: [_order(runSize: 50000)],
        tasks: [
          _task(
            status: TaskStatus.completed,
            comments: [
              _c('user_done', 'a', 'done'),
              _c('quantity_done', 'a', '24150'),
            ],
          ),
        ],
        stageMeta: _meta,
      );
      expect(issues, hasLength(1));
    });
  });

  /// Просрочка держится в списке до закрытия ПОСЛЕДНЕГО ЭТАПА — по этому и
  /// просили: пока производство идёт, срок ещё можно нагонять.
  group('просрочка', () {
    final now = DateTime(2026, 9, 10);

    List<ProductionIssue> overdueOf(OrderModel order,
            {List<TaskModel> tasks = const <TaskModel>[]}) =>
        collectProductionIssues(
          orders: [order],
          tasks: tasks,
          stageMeta: _meta,
          now: now,
        ).where((i) => i.kind == ProductionIssueKind.overdue).toList();

    test('срок прошёл, производство не закончено — срочно', () {
      final issues = overdueOf(_order(dueDate: DateTime(2026, 9, 7)));

      expect(issues, hasLength(1));
      expect(issues.single.severity, IssueSeverity.danger);
      expect(issues.single.title, 'Просрочен на 3 дня');
      expect(issues.single.detail, contains('07.09.2026'));
    });

    test('статус «завершён» снимает строку без completed_at', () {
      // Колонку completed_at начали заполнять только 09.09.2026: у заказов,
      // доделанных раньше, она пуста. Без этой ветки панель показывала их
      // просроченными вечно — так и набралось 117 строк.
      expect(
        overdueOf(_order(dueDate: DateTime(2026, 9, 1), status: 'completed')),
        isEmpty,
      );

      // Кусается: тот же заказ в производстве в списке есть.
      expect(
        overdueOf(_order(dueDate: DateTime(2026, 9, 1))),
        hasLength(1),
      );
    });

    test('закрытый последний этап снимает строку', () {
      expect(
        overdueOf(_order(
          dueDate: DateTime(2026, 9, 7),
          completedAt: DateTime(2026, 9, 9),
        )),
        isEmpty,
      );

      // Кусается: тот же заказ без отметки о завершении в списке есть.
      expect(overdueOf(_order(dueDate: DateTime(2026, 9, 7))), hasLength(1));
    });

    test('срок сегодня просрочкой не считается', () {
      expect(overdueOf(_order(dueDate: DateTime(2026, 9, 10))), isEmpty);
      // Кусается: вчерашний срок уже просрочка.
      expect(
        overdueOf(_order(dueDate: DateTime(2026, 9, 9))).single.title,
        'Просрочен на 1 день',
      );
    });

    test('заказ без срока не просрочен', () {
      expect(overdueOf(_order()), isEmpty);
    });

    test('отгруженный заказ в список не попадает', () {
      expect(
        overdueOf(_order(
          dueDate: DateTime(2026, 9, 1),
          shippedAt: DateTime(2026, 9, 5),
        )),
        isEmpty,
      );
    });

    test('строка показывает этап, на котором заказ стоит', () {
      final issues = overdueOf(
        _order(dueDate: DateTime(2026, 9, 1)),
        tasks: [
          _task(
            status: TaskStatus.inProgress,
            comments: [_c('start', 'a', '')],
          ),
        ],
      );

      expect(issues.single.stageName, 'Автомат большой');
    });

    test('счёт дней склоняется по-русски', () {
      String titleFor(int daysAgo) => overdueOf(
            _order(dueDate: now.subtract(Duration(days: daysAgo))),
          ).single.title;

      expect(titleFor(1), 'Просрочен на 1 день');
      expect(titleFor(2), 'Просрочен на 2 дня');
      expect(titleFor(5), 'Просрочен на 5 дней');
      expect(titleFor(11), 'Просрочен на 11 дней');
      expect(titleFor(21), 'Просрочен на 21 день');
    });
  });
}
