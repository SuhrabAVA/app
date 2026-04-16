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
