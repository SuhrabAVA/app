/// Что на производстве требует вмешательства прямо сейчас.
///
/// Одна функция собирает три разнородных повода в общий список:
///
///   * **количество** — завершённый этап разошёлся с тиражом (см.
///     [checkStageQuantity]);
///   * **проблема на этапе** — оператор нажал «Проблема» и работа встала;
///   * **материал** — заказ ждёт материала, материал не выбран или его не
///     хватает;
///   * **просрочка** — срок сдачи прошёл, а производство не закончено.
///
/// Расчёт вынесен из виджета намеренно: это единственное место, где решается,
/// считать ли ситуацию проблемой, и его нужно уметь проверить тестом, не
/// поднимая экран целиком.
///
/// Отсортировано по важности: красное выше жёлтого, внутри одного цвета —
/// свежее выше. Панель открывают, чтобы увидеть худшее, а не пролистать всё.
library;

import '../../utils/kostanay_time.dart';
import '../orders/order_model.dart';
import '../tasks/quantity_status_service.dart';
import '../tasks/stage_quantity_deviation.dart';
import '../tasks/stage_status_colors.dart';
import '../tasks/task_model.dart';
import '../tasks/task_run_state.dart';

/// Повод, по которому заказ попал в список.
enum ProductionIssueKind {
  /// Тираж завершённого этапа разошёлся с планом.
  quantity,

  /// На этапе зафиксирована проблема.
  stageProblem,

  /// Материал: ждём, не выбран или не хватает.
  material,

  /// Срок сдачи прошёл, а заказ ещё не сделан.
  ///
  /// Держится в списке до ЗАВЕРШЕНИЯ ПРОИЗВОДСТВА, а не до отгрузки: пока
  /// последний этап не закрыт, просрочку ещё можно нагонять — этим и
  /// занимаются, открывая эту панель. После закрытия догонять нечего, и строка
  /// превратилась бы в укор без действия.
  overdue,
}

/// Насколько всё плохо. Цвет берётся отсюда, а не из типа повода: этап с
/// отклонением в 3 % и этап в 50 % — разные истории.
enum IssueSeverity { warning, danger }

String issueKindLabel(ProductionIssueKind kind) => switch (kind) {
      ProductionIssueKind.quantity => 'Количество',
      ProductionIssueKind.stageProblem => 'Проблема',
      ProductionIssueKind.material => 'Материал',
      ProductionIssueKind.overdue => 'Просрочка',
    };

/// Всё, что нужно знать об этапе, чтобы сверить его количество.
class StageMeta {
  const StageMeta({
    required this.name,
    this.unit,
    this.splitByTime = true,
  });

  final String name;
  final String? unit;
  final bool splitByTime;
}

typedef StageMetaResolver = StageMeta Function(String stageId);

/// Одна строка списка проблем.
class ProductionIssue {
  const ProductionIssue({
    required this.order,
    required this.kind,
    required this.severity,
    required this.title,
    required this.detail,
    required this.at,
    this.stageName,
  });

  final OrderModel order;
  final ProductionIssueKind kind;
  final IssueSeverity severity;

  /// Короткая суть: «Недодали 52 %», «Расул попросил перезарядится».
  final String title;

  /// Подробность второй строкой: числа, сообщение о нехватке.
  final String detail;

  /// Этап, на котором возникло. `null` — повод относится к заказу целиком
  /// (материал).
  final String? stageName;

  /// Когда стало известно — по нему сортируются одинаково срочные строки.
  final DateTime at;

  String get customer => order.customer.trim();
}

/// Собирает список проблем по заказам и их задачам.
///
/// [tasks] — задачи ВСЕХ переданных заказов; группировка по заказу и шагу
/// маршрута делается здесь.
/// [now] — «сейчас» для просрочки. Параметром, а не внутренним
/// `DateTime.now()`: правило про срок иначе не проверить тестом, а один
/// незакреплённый тестом день — это ровно тот случай, когда «просрочен на
/// 1 день» и «сдан вовремя» меняются местами.
List<ProductionIssue> collectProductionIssues({
  required List<OrderModel> orders,
  required List<TaskModel> tasks,
  required StageMetaResolver stageMeta,
  DateTime? now,
}) {
  final moment = now ?? nowInKostanay();
  final issues = <ProductionIssue>[];

  final ordersById = <String, OrderModel>{
    for (final order in orders) order.id: order,
  };

  // Задачи по заказу и шагу маршрута: у переключаемых этапов (Высечка А1/А2)
  // задач несколько, а этап один.
  final byOrderStage = <String, Map<String, List<TaskModel>>>{};
  for (final task in tasks) {
    if (!ordersById.containsKey(task.orderId)) continue;
    final groupKey = task.stageGroupKey.trim().isEmpty
        ? task.stageId
        : task.stageGroupKey.trim();
    byOrderStage
        .putIfAbsent(task.orderId, () => <String, List<TaskModel>>{})
        .putIfAbsent(groupKey, () => <TaskModel>[])
        .add(task);
  }

  for (final order in orders) {
    // Отгруженный заказ уехал к заказчику — сделать с ним уже нечего:
    // ни пересчитать тираж, ни довезти материал. Держать его в списке значит
    // копить строки, по которым никто никогда не примет решения, и хоронить
    // под ними те, где решение ещё возможно.
    if (order.shippedAt != null) continue;

    issues.addAll(_materialIssues(order));

    final stages = byOrderStage[order.id];

    final overdue = _overdueIssue(
      order: order,
      now: moment,
      stageName: _currentStageName(stages, stageMeta),
    );
    if (overdue != null) issues.add(overdue);

    if (stages == null) continue;

    for (final entry in stages.entries) {
      final stageTasks = entry.value;
      if (stageTasks.isEmpty) continue;
      final meta = stageMeta(stageTasks.first.stageId);
      final runStatus = stageRunStatusForTasks(stageTasks);

      if (runStatus == StageRunStatus.problem) {
        issues.add(_stageProblemIssue(order, stageTasks, meta));
        // Этап уже в списке как проблемный: дублировать его же строкой про
        // количество незачем — разбираться всё равно придётся один раз.
        continue;
      }

      if (runStatus != StageRunStatus.completed) continue;

      final check = checkStageQuantity(
        order: order,
        stageTasks: stageTasks,
        unit: meta.unit,
        splitByTime: meta.splitByTime,
      );
      if (check == null || !check.isProblem) continue;

      issues.add(ProductionIssue(
        order: order,
        kind: ProductionIssueKind.quantity,
        severity: check.status == QuantityStatus.danger
            ? IssueSeverity.danger
            : IssueSeverity.warning,
        stageName: meta.name,
        title: check.isOver
            ? 'Передали ${check.signedPercentLabel}'
            : 'Недодали ${check.signedPercentLabel}',
        // Единица — та, в которой ИДЁТ СРАВНЕНИЕ, а не название рабочего
        // места. На упаковке место называется «пачка», но и план, и факт
        // считаются в штуках; подпись «49 из 5000 пачка» читалась как ошибка.
        detail: () {
          final unit = quantityInputUnit(meta.unit);
          return '${formatQuantityNumber(check.actual)} '
              'из ${formatQuantityNumber(check.expected)}'
              '${unit.isEmpty ? '' : ' $unit'}';
        }(),
        at: _lastCommentTime(stageTasks),
      ));
    }
  }

  issues.sort((a, b) {
    if (a.severity != b.severity) {
      return a.severity == IssueSeverity.danger ? -1 : 1;
    }
    return b.at.compareTo(a.at);
  });
  return issues;
}

/// Просроченный заказ; `null` — срок не вышел или производство закончено.
///
/// Завершением считается ЛЮБОЙ из двух признаков, и это не перестраховка.
///
///   * `completedAt` — момент закрытия последнего этапа. Точный, но молодой:
///     колонку начали заполнять только правкой 09.09.2026, и у всех заказов,
///     доделанных раньше, она пуста. Одного этого признака хватило, чтобы
///     панель насчитала 117 «просроченных» — почти все они давно сделаны;
///   * статус `completed` — старый и надёжный признак того же самого. Он
///     закрывает исторические заказы, до которых новая колонка не дошла.
///
/// Отгрузка признаком не служит: она случается днями позже, и по ней заказ
/// висел бы в списке уже сделанным.
///
/// Сравниваются КАЛЕНДАРНЫЕ ДНИ по костанайскому времени. Срок в заказе — это
/// дата, а не момент: заказ со сроком «сегодня» не просрочен ни в 9 утра, ни в
/// 23:59, и сравнение с точностью до секунды подняло бы его в красное на
/// полдня раньше правды.
ProductionIssue? _overdueIssue({
  required OrderModel order,
  required DateTime now,
  required String? stageName,
}) {
  final due = order.dueDate;
  if (due == null) return null;
  if (order.completedAt != null) return null;
  if (order.statusEnum == OrderStatus.completed) return null;

  final dueDay = _dayOnly(toKostanayTime(due));
  final today = _dayOnly(now);
  final days = today.difference(dueDay).inDays;
  if (days <= 0) return null;

  return ProductionIssue(
    order: order,
    kind: ProductionIssueKind.overdue,
    severity: IssueSeverity.danger,
    stageName: stageName,
    title: 'Просрочен на ${_daysLabel(days)}',
    detail: 'Срок ${_formatDay(dueDay)} — производство не закончено',
    // Свежесть повода — это сам срок: чем дольше просрочен, тем выше в списке
    // одинаково срочных строк.
    at: dueDay,
  );
}

DateTime _dayOnly(DateTime value) =>
    DateTime(value.year, value.month, value.day);

String _formatDay(DateTime day) =>
    '${day.day.toString().padLeft(2, '0')}.'
    '${day.month.toString().padLeft(2, '0')}.${day.year}';

/// «1 день», «3 дня», «11 дней» — правило русского счёта, без пакетов.
String _daysLabel(int days) {
  final mod100 = days % 100;
  final mod10 = days % 10;
  if (mod100 >= 11 && mod100 <= 14) return '$days дней';
  if (mod10 == 1) return '$days день';
  if (mod10 >= 2 && mod10 <= 4) return '$days дня';
  return '$days дней';
}

/// Этап, на котором заказ стоит сейчас; `null` — работа не идёт.
///
/// Нужен просрочке, чтобы строка отвечала на вопрос «где оно застряло». Берём
/// идущий этап, а при его отсутствии — приостановленный: остальные состояния
/// (не начат, доступен) на вопрос не отвечают.
String? _currentStageName(
  Map<String, List<TaskModel>>? stages,
  StageMetaResolver stageMeta,
) {
  if (stages == null) return null;
  String? paused;
  for (final stageTasks in stages.values) {
    if (stageTasks.isEmpty) continue;
    final status = stageRunStatusForTasks(stageTasks);
    final name = stageMeta(stageTasks.first.stageId).name;
    if (status == StageRunStatus.inProgress) return name;
    if (status == StageRunStatus.paused) paused ??= name;
  }
  return paused;
}

List<ProductionIssue> _materialIssues(OrderModel order) {
  final result = <ProductionIssue>[];
  final message = order.materialShortageMessage.trim();

  // У завершённого заказа признак нехватки не значит ничего: пересчёт до него
  // не доходит, и флаг остаётся с тех времён, когда материала не хватало. В
  // базе такие строки есть — заказ закрыт, а «не хватает краски» на нём висит.
  if (order.statusEnum == OrderStatus.completed) return result;

  if (order.hasMaterialShortage) {
    result.add(ProductionIssue(
      order: order,
      kind: ProductionIssueKind.material,
      severity: IssueSeverity.danger,
      // Уже запущенный заказ помечаем явно: иначе непонятно, почему его нет во
      // вкладке «Ожидание материалов» — она показывает только дозапускные.
      title: order.statusEnum == OrderStatus.in_production
          ? 'Не хватает материала (в производстве)'
          : 'Не хватает материала',
      detail: message.isEmpty ? 'Проверьте остатки на складе' : message,
      at: order.orderDate,
    ));
  } else if (order.statusEnum == OrderStatus.waiting_materials) {
    result.add(ProductionIssue(
      order: order,
      kind: ProductionIssueKind.material,
      severity: IssueSeverity.warning,
      title: 'Ожидает материала',
      detail: message.isEmpty ? 'Заказ не запущен в работу' : message,
      at: order.orderDate,
    ));
  }

  // Материал не выбран вовсе. Отдельный повод: «не хватает» и «не выбрали» —
  // разные действия, в первом случае звонят поставщику, во втором открывают
  // заказ и дозаполняют.
  final needsMaterial = order.statusEnum != OrderStatus.draft &&
      order.statusEnum != OrderStatus.completed;
  // Пустой позиции мало: заказ почти всегда приходит с одной строкой бумаги, у
  // незаполненной пустое имя. Проверяем именно его, иначе «не выбран» не
  // сработает никогда.
  final hasPaper =
      order.paperMaterials.any((m) => m.name.trim().isNotEmpty);
  if (needsMaterial && !hasPaper) {
    result.add(ProductionIssue(
      order: order,
      kind: ProductionIssueKind.material,
      severity: IssueSeverity.warning,
      title: 'Материал не выбран',
      detail: 'В заказе не указана бумага',
      at: order.orderDate,
    ));
  }

  return result;
}

ProductionIssue _stageProblemIssue(
  OrderModel order,
  List<TaskModel> stageTasks,
  StageMeta meta,
) {
  TaskComment? last;
  for (final task in stageTasks) {
    for (final comment in task.comments) {
      if (comment.type != 'problem') continue;
      if (last == null || comment.timestamp > last.timestamp) last = comment;
    }
  }
  final text = (last?.text ?? '').trim();
  return ProductionIssue(
    order: order,
    kind: ProductionIssueKind.stageProblem,
    severity: IssueSeverity.danger,
    stageName: meta.name,
    title: text.isEmpty ? 'Работа остановлена' : text,
    detail: 'Этап остановлен оператором',
    at: last == null
        ? order.orderDate
        : DateTime.fromMillisecondsSinceEpoch(
            normalizeEpochToMillis(last.timestamp),
            isUtc: true,
          ),
  );
}

DateTime _lastCommentTime(List<TaskModel> stageTasks) {
  var latest = 0;
  for (final task in stageTasks) {
    for (final comment in task.comments) {
      final ts = normalizeEpochToMillis(comment.timestamp);
      if (ts > latest) latest = ts;
    }
  }
  return latest == 0
      ? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true)
      : DateTime.fromMillisecondsSinceEpoch(latest, isUtc: true);
}
