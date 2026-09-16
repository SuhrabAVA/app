/// Состояние этапа и его исполнителей, вычисленное из задач.
///
/// Файл существует ради одного: цвет этапа считается одинаково в рабочем
/// пространстве, в модуле управления производственными заданиями и в деталях
/// задания. Раньше у каждого экрана была своя лесенка из `TaskStatus`, и они
/// расходились: в производстве завершённый этап зелёный, а ожидающий и
/// приостановленный — оба оранжевые, пересмены и доступности к началу там не
/// было вовсе.
library;

import 'task_buttons_state.dart' show UserRunState;
import 'task_completion_rules.dart';
import 'task_model.dart';
import 'stage_status_colors.dart';

/// Разобранные интервалы — по самому объекту задачи.
///
/// [TaskModel] неизменяем: любое изменение задачи создаёт новый объект
/// (`copyWith` в провайдере, `_rowToTask` при перечите), поэтому запись в
/// [Expando] не может протухнуть, а старые записи собирает GC вместе с
/// задачами. Инвалидировать вручную нечего.
///
/// Зачем: [taskTimeEvents] — самая горячая функция цеха. Каждый вызов делал
/// `jsonDecode` на КАЖДЫЙ интервал плюс два `DateTime.parse`, а вызывается она
/// из [userRunState] (дважды на исполнителя), [stageProductionStarted],
/// [isShiftPausedForTasks] и десятка мест экрана. На карточке задания это
/// выходило ~30 полных разборов, а карточек в списке рабочего места до 133
/// (Упаковка) — и весь этот разбор повторялся НА КАЖДЫЙ КАДР, пока едет
/// анимация клавиатуры или скролл.
final Expando<List<TaskTimeEvent>> _timeEventsByTask =
    Expando<List<TaskTimeEvent>>('taskTimeEvents');

/// Все интервалы времени этапа, отсортированные по началу.
///
/// Список неизменяемый: он общий для всех вызывающих, и правка на месте
/// испортила бы кэш. Сортировать и фильтровать — только на копии
/// (`.where(...).toList()`), как это и делают все места вызова.
List<TaskTimeEvent> taskTimeEvents(TaskModel task) {
  final cached = _timeEventsByTask[task];
  if (cached != null) return cached;

  final events = <TaskTimeEvent>[];
  for (final comment in task.comments) {
    if (comment.type != 'time_event') continue;
    final parsed = TaskTimeEvent.fromPayload(
        comment.text, comment.id, comment.timestamp, comment.userId);
    if (parsed != null) events.add(parsed);
  }
  events.sort((a, b) => a.startTime.compareTo(b.startTime));
  final result = List<TaskTimeEvent>.unmodifiable(events);
  _timeEventsByTask[task] = result;
  return result;
}

/// Интервалы конкретного исполнителя.
List<TaskTimeEvent> timeEventsForUser(TaskModel task, String userId) =>
    taskTimeEvents(task).where((e) => e.subjectUserId == userId).toList();

/// Незакрытый интервал исполнителя — по нему видно, чем он занят сейчас.
TaskTimeEvent? openEventForUser(TaskModel task, String userId) {
  final events =
      timeEventsForUser(task, userId).where((e) => e.endTime == null).toList();
  if (events.isEmpty) return null;
  events.sort((a, b) => a.startTime.compareTo(b.startTime));
  return events.last;
}

/// Что делает исполнитель на этапе в ТЕКУЩЕМ круге работы.
///
/// Круг отсчитывается от последнего возобновления (см.
/// [stageRoundStartMillis]): у возобновлённого этапа прошлая жизнь на его
/// состояние влиять не должна.
///
/// Приоритет источников: сначала интервалы времени (они точнее и знают про
/// наладку с пересменой), и только если их нет — текстовые комментарии старых
/// записей.
UserRunState userRunState(TaskModel task, String userId) {
  final roundStart = stageRoundStartMillis(task);
  final events = timeEventsForUser(task, userId)
      .where((e) => e.startTime.millisecondsSinceEpoch >= roundStart)
      .toList(growable: false);

  if (events.isNotEmpty) {
    final open = openEventForUser(task, userId);
    if (open != null && open.startTime.millisecondsSinceEpoch >= roundStart) {
      switch (open.type) {
        case TaskTimeType.production:
        case TaskTimeType.setup:
          return UserRunState.active;
        case TaskTimeType.pause:
        case TaskTimeType.shiftChange:
          return UserRunState.paused;
        case TaskTimeType.problem:
          return UserRunState.problem;
      }
    }
    final done = task.comments
        .where((c) =>
            c.type == 'user_done' &&
            c.userId == userId &&
            normalizeEpochToMillis(c.timestamp) >= roundStart)
        .toList()
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    if (done.isNotEmpty) {
      final lastStart = events
          .map((e) => e.startTime.millisecondsSinceEpoch)
          .fold<int>(0, (a, b) => a > b ? a : b);
      if (done.last.timestamp >= lastStart) return UserRunState.finished;
    }
    return UserRunState.idle;
  }

  final comments = task.comments
      .where((c) =>
          c.userId == userId &&
          normalizeEpochToMillis(c.timestamp) >= roundStart &&
          const {'start', 'pause', 'resume', 'user_done', 'problem'}
              .contains(c.type))
      .toList()
    ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
  if (comments.isEmpty) return UserRunState.idle;
  switch (comments.last.type) {
    case 'start':
    case 'resume':
      return UserRunState.active;
    case 'pause':
      return UserRunState.paused;
    case 'user_done':
      return UserRunState.finished;
    case 'problem':
      return UserRunState.problem;
    default:
      return UserRunState.idle;
  }
}

/// Начиналось ли производство на этапе.
bool stageProductionStarted(TaskModel task) {
  if (task.comments.any((c) => c.type == 'start')) return true;
  return taskTimeEvents(task)
      .any((event) => event.type == TaskTimeType.production);
}

/// Остановлен ли этап на пересмену.
///
/// Считается по всей группе задач: пересмену открывает один исполнитель, а
/// касается она этапа целиком.
bool isShiftPausedForTasks(Iterable<TaskModel> stageTasks) {
  final tasks = stageTasks.toList(growable: false);
  for (final task in tasks) {
    final open = taskTimeEvents(task).any(
      (e) => e.type == TaskTimeType.shiftChange && e.endTime == null,
    );
    if (open) return true;
  }

  final events = <TaskComment>[];
  for (final task in tasks) {
    for (final comment in task.comments) {
      if (comment.type == 'shift_pause' || comment.type == 'shift_resume') {
        events.add(comment);
      }
    }
  }
  if (events.isEmpty) return false;
  events.sort((a, b) => a.timestamp.compareTo(b.timestamp));
  return events.last.type == 'shift_pause';
}

/// Статус этапа для цветовой индикации — из задач его группы.
///
/// [stageTasks] — все задачи одного шага маршрута: у переключаемых этапов их
/// несколько (Высечка А1 и А2, три варианта склейки дна).
///
/// [availableToStart] экран считает сам: правило очереди у рабочего места и в
/// модуле производства разное, а состояние исполнителей — одно.
StageRunStatus stageRunStatusForTasks(
  Iterable<TaskModel> stageTasks, {
  bool availableToStart = false,
}) {
  final tasks = stageTasks.toList(growable: false);
  if (tasks.isEmpty) return StageRunStatus.notStarted;

  var anyProblem = false;
  var anyActive = false;
  var anyPaused = false;
  var started = false;
  var hasPerformers = false;
  var allPerformersFinished = true;

  for (final task in tasks) {
    if (task.status == TaskStatus.problem) anyProblem = true;
    if (stageProductionStarted(task)) started = true;
    if (task.assignees.isNotEmpty) hasPerformers = true;
    for (final userId in task.assignees) {
      switch (userRunState(task, userId)) {
        case UserRunState.problem:
          anyProblem = true;
          allPerformersFinished = false;
          break;
        case UserRunState.active:
          anyActive = true;
          allPerformersFinished = false;
          break;
        case UserRunState.paused:
          anyPaused = true;
          allPerformersFinished = false;
          break;
        case UserRunState.idle:
          allPerformersFinished = false;
          break;
        case UserRunState.finished:
          break;
      }
    }
  }

  return resolveStageRunStatus(
    finalized: isStageGroupFinallyCompleted(tasks),
    anyProblem: anyProblem,
    anyActive: anyActive,
    shiftPaused: isShiftPausedForTasks(tasks),
    hasPerformers: hasPerformers,
    allPerformersFinished: hasPerformers && allPerformersFinished,
    anyPaused: anyPaused,
    started: started,
    availableToStart: availableToStart,
  );
}
