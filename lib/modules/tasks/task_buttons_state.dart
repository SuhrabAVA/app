import 'task_model.dart';

/// Режим исполнения этапа.
///
/// `solo` — легаси-значение старых записей `exec_mode`; во всех расчётах оно
/// эквивалентно [ExecutionMode.joint].
enum ExecutionMode { solo, separate, joint }

/// Состояние конкретного сотрудника на этапе.
enum UserRunState { idle, active, paused, finished, problem }

/// Фаза строки кнопок — единственное, от чего зависит whitelist доступности.
///
/// Порядок определения важен: фазы проверяются сверху вниз в
/// [_resolvePhase], первое совпадение выигрывает.
enum TaskRowPhase {
  /// Этап окончательно завершён.
  completed,

  /// Этап остановлен на пересмену.
  shiftPaused,

  /// У сотрудника открыт интервал наладки.
  setupRunning,

  /// Наладка сотрудника не закрыта, сам он на паузе.
  setupPaused,

  /// Наладка сотрудника не закрыта, зафиксирована проблема.
  setupProblem,

  /// Идёт производственный отсчёт.
  productionRunning,

  /// Производство на паузе.
  productionPaused,

  /// Зафиксирована проблема (наладка при этом закрыта).
  problem,

  /// Сотрудник завершил участие, этап ещё открыт.
  finishedParticipation,

  /// Новый этап, требуется наладка станка.
  freshWithMachine,

  /// Новый этап без станка.
  freshWithoutMachine,

  /// Сотрудник простаивает на уже запущенном этапе: интервал закрыт извне
  /// (пересмена, возврат после личного завершения) либо он подключается к
  /// чужому запуску. Таблицами спецификации не описано — разрешаем только
  /// вход в работу.
  idleOnStartedStage,
}

/// Доступность одной кнопки.
class TaskButtonState {
  final bool visible;
  final bool enabled;
  final String label;

  const TaskButtonState({
    required this.visible,
    required this.enabled,
    required this.label,
  });

  const TaskButtonState.hidden({this.label = ''})
      : visible = false,
        enabled = false;

  @override
  String toString() =>
      'TaskButtonState(visible: $visible, enabled: $enabled, label: $label)';
}

/// Полный набор кнопок панели управления этапом.
class TaskButtonsState {
  /// «Начать наладку» / «Продолжить наладку».
  final TaskButtonState setup;

  /// «Начать» / «Продолжить» / «Вернуть в работу».
  final TaskButtonState start;

  /// «Пауза».
  final TaskButtonState pause;

  /// «Завершить» (joint) / «Завершить участие» (separate).
  final TaskButtonState finish;

  /// «Проблема».
  final TaskButtonState problem;

  /// «Пересмена» / «Продолжить пересмену».
  final TaskButtonState shift;

  /// Управление помощниками: добавить и удалить (общая доступность).
  final TaskButtonState helpers;

  /// Зелёная «Завершить задание» (только separate).
  final TaskButtonState finishTask;

  /// Фаза, из которой получен набор — для тестов и отладки.
  final TaskRowPhase phase;

  const TaskButtonsState({
    required this.setup,
    required this.start,
    required this.pause,
    required this.finish,
    required this.problem,
    required this.shift,
    required this.helpers,
    required this.finishTask,
    required this.phase,
  });
}

const String _labelSetupStart = 'Начать наладку';
const String _labelSetupResume = 'Продолжить наладку';
const String _labelStart = '▶ Начать';
const String _labelContinue = '▶ Продолжить';
const String _labelReturnToWork = '↩ Вернуть в работу';
const String _labelPause = '⏸ Пауза';
const String _labelFinishStage = '✓ Завершить';
const String _labelFinishParticipation = '✓ Завершить участие';
const String _labelProblem = '⚠ Проблема';
const String _labelShift = 'Пересмена';
const String _labelShiftResume = 'Продолжить пересмену';
const String _labelHelpers = 'Добавить помощника';
const String _labelFinishTask = 'Завершить задание';

/// Полноправный ли исполнитель строки — тот, чьи кнопки вообще могут быть
/// включены (см. `isAssignee` в [computeTaskButtons]).
///
/// Правило нужно двум разным местам экрана, и расхождение между ними уже
/// стоило регресса: панель показывала строку «Вы» сотруднику, заходящему на
/// этап вторым, а кнопка «Начать» в ней была выключена — начать работу было
/// нельзя вообще.
///
/// [rowMode] — режим самого сотрудника (`exec_mode`), [stageMode] — режим
/// этапа. Для незанесённого в [assignees] сотрудника [rowMode] не смотрим:
/// его записи режима ещё нет.
bool isRowAssignee({
  required List<String> assignees,
  required String rowUserId,
  required ExecutionMode stageMode,
  required ExecutionMode rowMode,
}) {
  // Этап ещё ничей: первый пришедший и становится исполнителем.
  if (assignees.isEmpty) return true;
  if (!assignees.contains(rowUserId)) {
    // Отдельные исполнители назначают себя сами, нажимая «Начать»: до
    // первого нажатия сотрудника нет в assignees. В совместном режиме
    // присоединиться самому нельзя — только через «Добавить помощника».
    return stageMode == ExecutionMode.separate;
  }
  if (rowMode == ExecutionMode.separate) return true;
  // Совместный режим: заданием управляет только основной исполнитель,
  // помощники — нет.
  return stageMode == ExecutionMode.joint && assignees.first == rowUserId;
}

TaskRowPhase _resolvePhase({
  required TaskStatus taskStatus,
  required UserRunState rowState,
  required bool hasMachine,
  required bool setupInProgressForRow,
  required bool setupUnfinishedForRow,
  required bool setupCompletedForStage,
  required bool productionStarted,
  required bool shiftPaused,
}) {
  if (taskStatus == TaskStatus.completed) return TaskRowPhase.completed;
  if (shiftPaused) return TaskRowPhase.shiftPaused;
  if (setupInProgressForRow) return TaskRowPhase.setupRunning;
  // Фазы незакрытой наладки имеют смысл только ДО запуска тиража. После него
  // «Продолжить наладку» всё равно выключено (`!productionStarted` в
  // setupEnabled), а фаз setupPaused/setupProblem нет в списке разрешённых для
  // «Начать» — строка оставалась вообще без единой доступной кнопки. Именно
  // так 09.09 заперся этап «Фри»: у сотрудника висела наладка, начатая накануне
  // и закрытая за него сменщиком, и кроме «Пересмены» нажать было нечего.
  if (!productionStarted && setupUnfinishedForRow) {
    if (rowState == UserRunState.paused) return TaskRowPhase.setupPaused;
    if (rowState == UserRunState.problem) return TaskRowPhase.setupProblem;
  }
  switch (rowState) {
    case UserRunState.active:
      return TaskRowPhase.productionRunning;
    case UserRunState.problem:
      return TaskRowPhase.problem;
    case UserRunState.paused:
      return TaskRowPhase.productionPaused;
    case UserRunState.finished:
      return TaskRowPhase.finishedParticipation;
    case UserRunState.idle:
      break;
  }
  if (productionStarted) return TaskRowPhase.idleOnStartedStage;
  return (hasMachine && !setupCompletedForStage)
      ? TaskRowPhase.freshWithMachine
      : TaskRowPhase.freshWithoutMachine;
}

/// Единственный источник истины по доступности кнопок этапа.
///
/// Функция чистая: никаких провайдеров, БД, `BuildContext` и состояния
/// виджета. Все входные флаги считает вызывающая сторона и обязательно —
/// относительно СТРОКИ (её сотрудника), а не текущего пользователя экрана.
///
/// Принцип: по умолчанию всё выключено, включаем только фазы из whitelist.
///
/// Отклонения от исходного черновика сигнатуры (все — вынужденные, чтобы не
/// менять поведение):
///  * [startBlockedExternally] объединяет все внешние запреты старта, которые
///    считаются по провайдерам: очередь рабочего места, блокировка группы
///    этапов, конфликт активных заданий, последовательность этапов, лок после
///    возобновления смены и незакрытое намерение старта;
///  * [shiftResumeBlocked] — отдельный флаг для «Продолжить пересмену»: он
///    считается по другим правилам (доступ к рабочему месту, а не назначение);
///  * [startInFlight] / [setupInFlight] / [shiftInFlight] / [finishInFlight] —
///    защита от повторного нажатия, пока запрос выполняется;
///  * [setupPendingForStage] — у кого-то на этапе висит незакрытая наладка;
///  * [hasAssignees] — нужен только для видимости «Завершить задание».
TaskButtonsState computeTaskButtons({
  required TaskStatus taskStatus,
  required UserRunState rowState,
  required bool isMyRow,
  required bool isOwner,
  required bool isAssignee,
  required ExecutionMode mode,
  required bool hasMachine,
  required bool setupCompletedForStage,
  required bool setupPendingForStage,
  required bool setupInProgressForRow,
  required bool setupUnfinishedForRow,
  required bool productionStarted,
  required bool participated,
  required bool shiftPaused,
  required bool startBlockedExternally,
  required bool shiftResumeBlocked,
  required bool startInFlight,
  required bool setupInFlight,
  required bool hasAssignees,
  required bool allPerformersFinished,
  required bool anyUserActive,
  // Этап возобновлён после завершения («Возобновить»), а в новом круге ещё
  // ничего не начато. Станок уже налажен прошлым кругом: доступны и
  // «Начать наладку», и сразу «Начать».
  bool stageReopened = false,
  // Пересмена и завершение спрашивают расход бумаги и количество: между
  // нажатием и записью проходят секунды, и всё это время кнопка оставалась
  // живой. Второе нажатие писало вторую пересмену, второе количество и второе
  // списание бумаги.
  bool shiftInFlight = false,
  bool finishInFlight = false,
}) {
  final bool joint = mode != ExecutionMode.separate;

  final TaskRowPhase phase = _resolvePhase(
    taskStatus: taskStatus,
    rowState: rowState,
    hasMachine: hasMachine,
    setupInProgressForRow: setupInProgressForRow,
    setupUnfinishedForRow: setupUnfinishedForRow,
    setupCompletedForStage: setupCompletedForStage,
    productionStarted: productionStarted,
    shiftPaused: shiftPaused,
  );

  // === Наладка ==============================================================
  // Whitelist фаз: новый этап со станком и возобновление собственной наладки.
  const setupPhases = {
    TaskRowPhase.freshWithMachine,
    TaskRowPhase.setupPaused,
    TaskRowPhase.setupProblem,
  };
  final bool setupEnabled = setupPhases.contains(phase) &&
      hasMachine &&
      isMyRow &&
      isAssignee &&
      !setupInFlight &&
      // Наладка — вход в этап, поэтому подчиняется тем же внешним запретам,
      // что и «Начать».
      !startBlockedExternally &&
      !productionStarted &&
      !setupCompletedForStage &&
      (!setupPendingForStage || setupUnfinishedForRow);
  final setup = TaskButtonState(
    visible: hasMachine && isMyRow,
    enabled: setupEnabled,
    label: setupUnfinishedForRow ? _labelSetupResume : _labelSetupStart,
  );

  // === Начать / Продолжить / Вернуть в работу ===============================
  const startPhases = {
    // «Начать» во время наладки завершает наладку и запускает производство.
    TaskRowPhase.setupRunning,
    TaskRowPhase.productionPaused,
    TaskRowPhase.problem,
    TaskRowPhase.finishedParticipation,
    TaskRowPhase.freshWithoutMachine,
    TaskRowPhase.idleOnStartedStage,
  };
  final bool startEnabled = (startPhases.contains(phase) ||
          (phase == TaskRowPhase.freshWithMachine && stageReopened)) &&
      isMyRow &&
      isAssignee &&
      !startInFlight &&
      !startBlockedExternally &&
      // В совместном режиме после личного завершения этап уже закрыт —
      // возврат к работе через эту строку недоступен.
      (phase != TaskRowPhase.finishedParticipation || !joint);
  final String startLabel;
  switch (rowState) {
    case UserRunState.problem:
      startLabel = _labelReturnToWork;
      break;
    case UserRunState.paused:
      startLabel = _labelContinue;
      break;
    case UserRunState.finished:
      startLabel = joint ? _labelStart : _labelContinue;
      break;
    case UserRunState.idle:
    case UserRunState.active:
      startLabel = _labelStart;
      break;
  }
  final start = TaskButtonState(
    visible: true,
    enabled: startEnabled,
    label: startLabel,
  );

  // === Пауза ================================================================
  const pausePhases = {
    TaskRowPhase.setupRunning,
    TaskRowPhase.productionRunning,
  };
  final pause = TaskButtonState(
    visible: true,
    enabled: pausePhases.contains(phase) &&
        isMyRow &&
        isAssignee &&
        taskStatus == TaskStatus.inProgress,
    label: _labelPause,
  );

  // === Завершить / Завершить участие ========================================
  const finishPhases = {
    TaskRowPhase.productionRunning,
    TaskRowPhase.productionPaused,
    TaskRowPhase.problem,
  };
  const finishStatuses = {
    TaskStatus.inProgress,
    TaskStatus.paused,
    TaskStatus.problem,
  };
  final finish = TaskButtonState(
    visible: true,
    enabled: finishPhases.contains(phase) &&
        isMyRow &&
        isAssignee &&
        !finishInFlight &&
        finishStatuses.contains(taskStatus) &&
        productionStarted &&
        participated,
    label: joint ? _labelFinishStage : _labelFinishParticipation,
  );

  // === Проблема =============================================================
  const problemPhases = {
    TaskRowPhase.setupRunning,
    TaskRowPhase.productionRunning,
  };
  final problem = TaskButtonState(
    visible: true,
    enabled: problemPhases.contains(phase) &&
        isMyRow &&
        isAssignee &&
        taskStatus == TaskStatus.inProgress,
    label: _labelProblem,
  );

  // === Пересмена ============================================================
  // В режиме отдельных исполнителей кнопки нет вовсе.
  const shiftPhases = {
    TaskRowPhase.setupRunning,
    TaskRowPhase.setupPaused,
    TaskRowPhase.setupProblem,
    TaskRowPhase.productionRunning,
    TaskRowPhase.productionPaused,
    TaskRowPhase.problem,
  };
  final bool shiftEnabled = !shiftInFlight &&
      (phase == TaskRowPhase.shiftPaused
          ? (isMyRow && !shiftResumeBlocked)
          : (shiftPhases.contains(phase) && isMyRow));
  final shift = TaskButtonState(
    visible: joint,
    enabled: joint && shiftEnabled,
    label: shiftPaused ? _labelShiftResume : _labelShift,
  );

  // === Помощники ============================================================
  const helperPhases = {
    TaskRowPhase.setupRunning,
    TaskRowPhase.productionRunning,
  };
  final helpers = TaskButtonState(
    visible: joint && isOwner && isMyRow,
    enabled: helperPhases.contains(phase) && joint && isOwner && isMyRow,
    label: _labelHelpers,
  );

  // === Завершить задание ====================================================
  // Панельная кнопка: от состояния конкретной строки не зависит.
  final finishTask = TaskButtonState(
    visible: !joint && hasAssignees,
    enabled: !joint &&
        hasAssignees &&
        taskStatus != TaskStatus.completed &&
        productionStarted &&
        allPerformersFinished &&
        !anyUserActive,
    label: _labelFinishTask,
  );

  return TaskButtonsState(
    setup: setup,
    start: start,
    pause: pause,
    finish: finish,
    problem: problem,
    shift: shift,
    helpers: helpers,
    finishTask: finishTask,
    phase: phase,
  );
}
