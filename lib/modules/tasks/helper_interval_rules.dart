import 'task_buttons_state.dart' show ExecutionMode;
import 'task_model.dart';

/// Кому из бригады рассылать интервал вместе с основным исполнителем.
///
/// Пауза, проблема, пересмена и старт в совместном режиме — действия НАД ВСЕЙ
/// бригадой: основной исполнитель нажимает кнопку, а интервал должен получить
/// каждый, кто на этапе. Список обязан браться из САМОЙ СВЕЖЕЙ задачи, а не из
/// снимка, с которым отрисовался экран.
///
/// Чем это кончилось на заказе ЗК-2026.08.26-1 («Ручка-склейка крученая»):
/// экран отрисовался в 12:21:42, после чего к этапу присоединились ещё двое —
/// в 12:21:48 и 12:22:06. В 12:59 основной исполнитель нажал «Пауза» на обед,
/// рассылка прошла по устаревшему списку из четырёх человек, и у двоих
/// последних производственный интервал не закрылся. Он тянулся сквозь час
/// обеда до конца этапа, времени у них вышло вдвое больше, и сервер начислил
/// вдвое большую долю: 988 и 986 против 478 у остальных.
///
/// [execModeOf] — режим конкретного участника (`exec_mode` в комментариях).
/// Отдельные исполнители в рассылку не идут: у них своя кнопка и свой интервал.
List<String> jointHelperIds({
  required List<String> assignees,
  required ExecutionMode? Function(String userId) execModeOf,
}) {
  if (assignees.isEmpty) return const <String>[];
  final owner = assignees.first.trim();
  final result = <String>[];
  final seen = <String>{owner};
  for (final id in assignees) {
    final userId = id.trim();
    if (userId.isEmpty || !seen.add(userId)) continue;
    if (execModeOf(userId) == ExecutionMode.separate) continue;
    result.add(userId);
  }
  return result;
}

/// Нужен ли помощнику собственный интервал в момент добавления к этапу.
///
/// Интервалы помощникам заводит основной исполнитель своими действиями
/// (старт, пауза, завершение). Но помощника добавляют посреди работы, когда
/// старт уже нажат, — и до следующего действия основного у помощника нет ни
/// одного интервала. В аналитике его время складывалось тогда только из
/// минутных fallback-событий количества: этап шёл час, а в таблице стояла
/// «1 мин» и скорость в десятки тысяч штук в минуту. Хуже того, из таких
/// минут не набиралось полсмены — и смена помощнику не засчитывалась.
class HelperIntervalDecision {
  const HelperIntervalDecision._(this.shouldOpen, this.type);

  const HelperIntervalDecision.skip() : this._(false, null);

  const HelperIntervalDecision.open(TaskTimeType type) : this._(true, type);

  final bool shouldOpen;

  /// Тип интервала — тот же, что сейчас у основного исполнителя.
  final TaskTimeType? type;
}

/// Решение по одному помощнику.
///
/// [assignees] — исполнители задачи; первый считается основным (это же
/// правило действует в рабочем пространстве: «Добавлять помощников может
/// только основной исполнитель»).
HelperIntervalDecision decideHelperInterval({
  required List<String> assignees,
  required List<TaskTimeEvent> timeEvents,
  required String helperId,
}) {
  if (helperId.isEmpty) return const HelperIntervalDecision.skip();

  final ownerId = assignees.isEmpty ? '' : assignees.first;
  // Некому подражать, либо это и есть основной исполнитель: он начнёт этап
  // сам, и интервал ему заведёт кнопка «Начать».
  if (ownerId.isEmpty || ownerId == helperId) {
    return const HelperIntervalDecision.skip();
  }

  // Уже есть открытый интервал — второй сломал бы учёт времени.
  if (_openEventOf(timeEvents, helperId) != null) {
    return const HelperIntervalDecision.skip();
  }

  final ownerOpen = _openEventOf(timeEvents, ownerId);
  // Этап ещё не запущен — помощник начнёт вместе с основным.
  if (ownerOpen == null) return const HelperIntervalDecision.skip();

  // Тип копируем: если этап на паузе, помощник получает паузу, а не
  // производство, иначе ему капало бы рабочее время на стоящем станке.
  return HelperIntervalDecision.open(ownerOpen.type);
}

TaskTimeEvent? _openEventOf(List<TaskTimeEvent> events, String userId) {
  TaskTimeEvent? latest;
  for (final event in events) {
    if (event.subjectUserId != userId) continue;
    if (event.endTime != null) continue;
    if (latest == null || event.startTime.isAfter(latest.startTime)) {
      latest = event;
    }
  }
  return latest;
}
