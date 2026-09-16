/// Сошёлся ли тираж этапа с планом.
///
/// Один расчёт на два экрана: пульсирующая точка на карточке заказа и список
/// проблем в панели администратора. Разъехавшись, они дали бы два разных
/// ответа на вопрос «этот этап сделан правильно или нет» — а это ровно тот
/// вопрос, ради которого точку и список заводили.
///
/// Границы отклонения живут в [quantity_status_service]: до 2 % — норма,
/// до 10 % — жёлтый, дальше красный. Знак отклонения не важен: недодали или
/// передали — разбираться нужно одинаково, поэтому берётся модуль.
library;

import '../orders/order_model.dart';
import 'quantity_status_service.dart';
import 'stage_participant_output.dart';
import 'task_model.dart';

/// Результат сверки тиража этапа с планом.
class StageQuantityCheck {
  const StageQuantityCheck({
    required this.status,
    required this.actual,
    required this.expected,
    required this.deviation,
  });

  final QuantityStatus status;

  /// Сколько сделали на этапе за текущий круг.
  final double actual;

  /// Сколько должны были по заказу.
  final double expected;

  /// Доля отклонения от плана, всегда ≥ 0.
  final double deviation;

  /// Отклонение вышло за норму — этап требует внимания.
  bool get isProblem =>
      status == QuantityStatus.warning || status == QuantityStatus.danger;

  /// Сделали больше плана. Для подписи «+12 %» / «−12 %».
  bool get isOver => actual > expected;

  /// Отклонение в процентах со знаком: «+12 %», «−3 %».
  String get signedPercentLabel {
    final percent = deviation * 100;
    final rounded = percent >= 10 ? percent.round().toString()
        : percent.toStringAsFixed(1).replaceFirst(RegExp(r'\.0$'), '');
    return '${isOver ? '+' : '−'}$rounded %';
  }
}

/// Сверяет тираж этапа с планом заказа.
///
/// `null` — сверять нечего: количество ещё не вводили либо план неизвестен
/// (не задан тираж, у рабочего места нет единицы измерения). Молчание тут
/// честнее нуля: «плана нет» и «сделали ноль» — разные вещи.
///
/// [stageTasks] — все задачи одного шага маршрута: у переключаемых этапов их
/// несколько (Высечка А1 и А2, три варианта склейки дна).
StageQuantityCheck? checkStageQuantity({
  required OrderModel? order,
  required List<TaskModel> stageTasks,
  required String? unit,
  bool splitByTime = true,
}) {
  if (order == null || stageTasks.isEmpty) return null;

  final output = stageOutputForTasks(stageTasks, splitByTime: splitByTime);
  if (!output.hasTotal) return null;

  final expected = getExpectedQuantity(
    order: order,
    task: stageTasks.first,
    unit: unit ?? '',
  );
  final deviation = quantityDeviation(
    actual: output.totalQty,
    expected: expected,
  );
  if (expected == null || deviation == null) return null;

  return StageQuantityCheck(
    status: getQuantityStatus(actual: output.totalQty, expected: expected),
    actual: output.totalQty,
    expected: expected,
    deviation: deviation,
  );
}
