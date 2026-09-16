import 'task_model.dart';

/// Финальная завершённость конкретной задачи/ветки этапа.
///
/// Важно: для режима "отдельный исполнитель" промежуточные признаки
/// (например, `user_done`) не считаются окончательным завершением — только
/// статус `completed` после отдельного подтверждения.
bool isTaskFinallyCompleted(TaskModel task) => task.status == TaskStatus.completed;

String stageGroupKeyForTask(TaskModel task) {
  final key = task.stageGroupKey.trim();
  if (key.isNotEmpty) return key;
  return task.stageId.trim();
}

/// Группа этапа (включая альтернативные рабочие места) считается завершённой,
/// когда хотя бы одна выбранная ветка (stage_id) завершена полностью.
bool isStageGroupFinallyCompleted(List<TaskModel> groupTasks) {
  if (groupTasks.isEmpty) return false;
  final tasksByStage = <String, List<TaskModel>>{};
  for (final task in groupTasks) {
    final stageId = task.stageId.trim();
    if (stageId.isEmpty) continue;
    tasksByStage.putIfAbsent(stageId, () => <TaskModel>[]).add(task);
  }
  if (tasksByStage.isEmpty) return false;
  for (final stageTasks in tasksByStage.values) {
    if (stageTasks.isNotEmpty && stageTasks.every(isTaskFinallyCompleted)) {
      return true;
    }
  }
  return false;
}

bool isOrderFinallyCompleted(Iterable<TaskModel> orderTasks) {
  final tasks = orderTasks.toList(growable: false);
  if (tasks.isEmpty) return false;
  final tasksByGroup = <String, List<TaskModel>>{};
  for (final task in tasks) {
    final key = stageGroupKeyForTask(task);
    if (key.isEmpty) continue;
    tasksByGroup.putIfAbsent(key, () => <TaskModel>[]).add(task);
  }
  if (tasksByGroup.isEmpty) return false;
  return tasksByGroup.values.every(isStageGroupFinallyCompleted);
}

/// Начало ТЕКУЩЕГО круга работы по этапу — момент последнего возобновления
/// завершённого этапа (комментарий `stage_reopened`, пишет
/// [TaskProvider.reopenStageGroup]). 0 — этап ни разу не возобновляли.
///
/// Возобновление намеренно сохраняет историю: время и количество после него
/// дополняются, а не переписываются. Но состояние сотрудника «завершил
/// участие» относится к прошлому кругу — если считать его и после
/// возобновления, этап нельзя начать заново: в совместном режиме кнопка
/// «Начать» после личного завершения выключена, и запуск блокируется как
/// конфликт.
int stageRoundStartMillis(TaskModel task) {
  var latest = 0;
  for (final c in task.comments) {
    if (c.type != 'stage_reopened') continue;
    final ts = normalizeEpochToMillis(c.timestamp);
    if (ts > latest) latest = ts;
  }
  return latest;
}
