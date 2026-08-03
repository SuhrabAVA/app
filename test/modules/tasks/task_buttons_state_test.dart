import 'package:flutter_test/flutter_test.dart';
import 'package:sheet_clone/modules/tasks/task_buttons_state.dart';
import 'package:sheet_clone/modules/tasks/task_model.dart';

/// Ожидаемая доступность всего набора кнопок.
///
/// Каждый кейс перечисляет ВСЕ кнопки — и активные, и неактивные, чтобы
/// проверка ловила не только целевую кнопку, но и случайное «протекание»
/// соседних.
class _Expect {
  final bool setup;
  final bool start;
  final bool pause;
  final bool finish;
  final bool problem;
  final bool shift;
  final bool helpers;
  final bool finishTask;

  const _Expect({
    this.setup = false,
    this.start = false,
    this.pause = false,
    this.finish = false,
    this.problem = false,
    this.shift = false,
    this.helpers = false,
    this.finishTask = false,
  });
}

void _expectButtons(TaskButtonsState actual, _Expect expected) {
  final got = <String, bool>{
    'setup': actual.setup.enabled,
    'start': actual.start.enabled,
    'pause': actual.pause.enabled,
    'finish': actual.finish.enabled,
    'problem': actual.problem.enabled,
    'shift': actual.shift.enabled,
    'helpers': actual.helpers.enabled,
    'finishTask': actual.finishTask.enabled,
  };
  final want = <String, bool>{
    'setup': expected.setup,
    'start': expected.start,
    'pause': expected.pause,
    'finish': expected.finish,
    'problem': expected.problem,
    'shift': expected.shift,
    'helpers': expected.helpers,
    'finishTask': expected.finishTask,
  };
  expect(got, want, reason: 'фаза: ${actual.phase}');
}

/// Все входы со значениями «ничего не мешает»; кейс переопределяет только то,
/// что описывает его строку таблицы спецификации.
TaskButtonsState build({
  TaskStatus taskStatus = TaskStatus.waiting,
  UserRunState rowState = UserRunState.idle,
  bool isMyRow = true,
  bool isOwner = true,
  bool isAssignee = true,
  ExecutionMode mode = ExecutionMode.joint,
  bool hasMachine = false,
  bool setupCompletedForStage = false,
  bool setupPendingForStage = false,
  bool setupInProgressForRow = false,
  bool setupUnfinishedForRow = false,
  bool productionStarted = false,
  bool participated = false,
  bool shiftPaused = false,
  bool startBlockedExternally = false,
  bool shiftResumeBlocked = false,
  bool startInFlight = false,
  bool setupInFlight = false,
  bool hasAssignees = true,
  bool allPerformersFinished = false,
  bool anyUserActive = false,
}) {
  return computeTaskButtons(
    taskStatus: taskStatus,
    rowState: rowState,
    isMyRow: isMyRow,
    isOwner: isOwner,
    isAssignee: isAssignee,
    mode: mode,
    hasMachine: hasMachine,
    setupCompletedForStage: setupCompletedForStage,
    setupPendingForStage: setupPendingForStage,
    setupInProgressForRow: setupInProgressForRow,
    setupUnfinishedForRow: setupUnfinishedForRow,
    productionStarted: productionStarted,
    participated: participated,
    shiftPaused: shiftPaused,
    startBlockedExternally: startBlockedExternally,
    shiftResumeBlocked: shiftResumeBlocked,
    startInFlight: startInFlight,
    setupInFlight: setupInFlight,
    hasAssignees: hasAssignees,
    allPerformersFinished: allPerformersFinished,
    anyUserActive: anyUserActive,
  );
}

void main() {
  group('Совместное исполнение', () {
    test('Новый этап со станком — активна только «Начать наладку»', () {
      final b = build(hasMachine: true);
      expect(b.phase, TaskRowPhase.freshWithMachine);
      expect(b.setup.label, 'Начать наладку');
      _expectButtons(b, const _Expect(setup: true));
    });

    test('Новый этап без станка — активна только «Начать»', () {
      final b = build();
      expect(b.phase, TaskRowPhase.freshWithoutMachine);
      expect(b.setup.visible, isFalse);
      expect(b.start.label, '▶ Начать');
      _expectButtons(b, const _Expect(start: true));
    });

    test('Наладка выполняется — Начать, Пауза, Проблема, Пересмена, помощники',
        () {
      final b = build(
        taskStatus: TaskStatus.inProgress,
        rowState: UserRunState.active,
        hasMachine: true,
        setupPendingForStage: true,
        setupInProgressForRow: true,
        setupUnfinishedForRow: true,
        participated: true,
      );
      expect(b.phase, TaskRowPhase.setupRunning);
      _expectButtons(
        b,
        const _Expect(start: true, pause: true, problem: true, shift: true, helpers: true),
      );
    });

    test('Наладка на паузе — Продолжить наладку и Пересмена', () {
      final b = build(
        taskStatus: TaskStatus.paused,
        rowState: UserRunState.paused,
        hasMachine: true,
        setupPendingForStage: true,
        setupUnfinishedForRow: true,
        participated: true,
      );
      expect(b.phase, TaskRowPhase.setupPaused);
      expect(b.setup.label, 'Продолжить наладку');
      _expectButtons(b, const _Expect(setup: true, shift: true));
    });

    test('Проблема во время наладки — Продолжить наладку и Пересмена', () {
      final b = build(
        taskStatus: TaskStatus.problem,
        rowState: UserRunState.problem,
        hasMachine: true,
        setupPendingForStage: true,
        setupUnfinishedForRow: true,
        participated: true,
      );
      expect(b.phase, TaskRowPhase.setupProblem);
      expect(b.setup.label, 'Продолжить наладку');
      _expectButtons(b, const _Expect(setup: true, shift: true));
    });

    test('Производство выполняется — Пауза, Завершить, Проблема, Пересмена, помощники',
        () {
      final b = build(
        taskStatus: TaskStatus.inProgress,
        rowState: UserRunState.active,
        hasMachine: true,
        setupCompletedForStage: true,
        productionStarted: true,
        participated: true,
      );
      expect(b.phase, TaskRowPhase.productionRunning);
      expect(b.finish.label, '✓ Завершить');
      _expectButtons(
        b,
        const _Expect(pause: true, finish: true, problem: true, shift: true, helpers: true),
      );
    });

    test('Производство на паузе — Продолжить, Завершить, Пересмена', () {
      final b = build(
        taskStatus: TaskStatus.paused,
        rowState: UserRunState.paused,
        hasMachine: true,
        setupCompletedForStage: true,
        productionStarted: true,
        participated: true,
      );
      expect(b.phase, TaskRowPhase.productionPaused);
      expect(b.start.label, '▶ Продолжить');
      _expectButtons(b, const _Expect(start: true, finish: true, shift: true));
    });

    test('Зафиксирована проблема — Вернуть в работу, Завершить, Пересмена', () {
      final b = build(
        taskStatus: TaskStatus.problem,
        rowState: UserRunState.problem,
        hasMachine: true,
        setupCompletedForStage: true,
        productionStarted: true,
        participated: true,
      );
      expect(b.phase, TaskRowPhase.problem);
      expect(b.start.label, '↩ Вернуть в работу');
      _expectButtons(b, const _Expect(start: true, finish: true, shift: true));
    });

    test('Остановлен на пересмену — только «Продолжить пересмену»', () {
      final b = build(
        taskStatus: TaskStatus.inProgress,
        rowState: UserRunState.paused,
        hasMachine: true,
        setupCompletedForStage: true,
        productionStarted: true,
        participated: true,
        shiftPaused: true,
      );
      expect(b.phase, TaskRowPhase.shiftPaused);
      expect(b.shift.label, 'Продолжить пересмену');
      _expectButtons(b, const _Expect(shift: true));
    });

    test('Этап завершён — всё выключено', () {
      final b = build(
        taskStatus: TaskStatus.completed,
        rowState: UserRunState.finished,
        hasMachine: true,
        setupCompletedForStage: true,
        productionStarted: true,
        participated: true,
        allPerformersFinished: true,
      );
      expect(b.phase, TaskRowPhase.completed);
      _expectButtons(b, const _Expect());
    });

    test('«Завершить задание» в совместном режиме не показывается', () {
      final b = build(
        taskStatus: TaskStatus.inProgress,
        rowState: UserRunState.active,
        productionStarted: true,
        participated: true,
      );
      expect(b.finishTask.visible, isFalse);
    });

    test('Помощниками управляет только владелец', () {
      final b = build(
        taskStatus: TaskStatus.inProgress,
        rowState: UserRunState.active,
        isOwner: false,
        productionStarted: true,
        participated: true,
      );
      expect(b.helpers.visible, isFalse);
      expect(b.helpers.enabled, isFalse);
    });

    test('Чужая строка: все кнопки выключены', () {
      final b = build(
        taskStatus: TaskStatus.inProgress,
        rowState: UserRunState.active,
        isMyRow: false,
        productionStarted: true,
        participated: true,
      );
      _expectButtons(b, const _Expect());
    });
  });

  group('Отдельный исполнитель', () {
    TaskButtonsState sep({
      TaskStatus taskStatus = TaskStatus.waiting,
      UserRunState rowState = UserRunState.idle,
      bool hasMachine = false,
      bool setupCompletedForStage = false,
      bool setupPendingForStage = false,
      bool setupInProgressForRow = false,
      bool setupUnfinishedForRow = false,
      bool productionStarted = false,
      bool participated = false,
      bool allPerformersFinished = false,
      bool anyUserActive = false,
    }) =>
        build(
          mode: ExecutionMode.separate,
          taskStatus: taskStatus,
          rowState: rowState,
          hasMachine: hasMachine,
          setupCompletedForStage: setupCompletedForStage,
          setupPendingForStage: setupPendingForStage,
          setupInProgressForRow: setupInProgressForRow,
          setupUnfinishedForRow: setupUnfinishedForRow,
          productionStarted: productionStarted,
          participated: participated,
          allPerformersFinished: allPerformersFinished,
          anyUserActive: anyUserActive,
        );

    test('Новый этап со станком — активна только «Начать наладку»', () {
      final b = sep(hasMachine: true);
      expect(b.phase, TaskRowPhase.freshWithMachine);
      _expectButtons(b, const _Expect(setup: true));
    });

    test('Новый этап без станка — активна только «Начать»', () {
      final b = sep();
      expect(b.phase, TaskRowPhase.freshWithoutMachine);
      _expectButtons(b, const _Expect(start: true));
    });

    test('Выполняет наладку — Начать, Пауза, Проблема', () {
      final b = sep(
        taskStatus: TaskStatus.inProgress,
        rowState: UserRunState.active,
        hasMachine: true,
        setupPendingForStage: true,
        setupInProgressForRow: true,
        setupUnfinishedForRow: true,
        participated: true,
      );
      expect(b.phase, TaskRowPhase.setupRunning);
      _expectButtons(b, const _Expect(start: true, pause: true, problem: true));
    });

    test('Наладка на паузе — только «Продолжить наладку»', () {
      final b = sep(
        taskStatus: TaskStatus.paused,
        rowState: UserRunState.paused,
        hasMachine: true,
        setupPendingForStage: true,
        setupUnfinishedForRow: true,
        participated: true,
      );
      expect(b.phase, TaskRowPhase.setupPaused);
      _expectButtons(b, const _Expect(setup: true));
    });

    test('Проблема во время наладки — только «Продолжить наладку»', () {
      final b = sep(
        taskStatus: TaskStatus.problem,
        rowState: UserRunState.problem,
        hasMachine: true,
        setupPendingForStage: true,
        setupUnfinishedForRow: true,
        participated: true,
      );
      expect(b.phase, TaskRowPhase.setupProblem);
      _expectButtons(b, const _Expect(setup: true));
    });

    test('Выполняет производство — Пауза, Завершить участие, Проблема', () {
      final b = sep(
        taskStatus: TaskStatus.inProgress,
        rowState: UserRunState.active,
        productionStarted: true,
        participated: true,
        anyUserActive: true,
      );
      expect(b.phase, TaskRowPhase.productionRunning);
      expect(b.finish.label, '✓ Завершить участие');
      _expectButtons(b, const _Expect(pause: true, finish: true, problem: true));
    });

    test('На паузе — Продолжить и Завершить участие', () {
      final b = sep(
        taskStatus: TaskStatus.paused,
        rowState: UserRunState.paused,
        productionStarted: true,
        participated: true,
      );
      expect(b.phase, TaskRowPhase.productionPaused);
      expect(b.start.label, '▶ Продолжить');
      _expectButtons(b, const _Expect(start: true, finish: true));
    });

    test('Проблема — Вернуть в работу и Завершить участие', () {
      final b = sep(
        taskStatus: TaskStatus.problem,
        rowState: UserRunState.problem,
        productionStarted: true,
        participated: true,
      );
      expect(b.phase, TaskRowPhase.problem);
      expect(b.start.label, '↩ Вернуть в работу');
      _expectButtons(b, const _Expect(start: true, finish: true));
    });

    test('Завершил участие — только «Продолжить» (этап ещё открыт)', () {
      final b = sep(
        taskStatus: TaskStatus.inProgress,
        rowState: UserRunState.finished,
        productionStarted: true,
        participated: true,
        anyUserActive: true,
      );
      expect(b.phase, TaskRowPhase.finishedParticipation);
      expect(b.start.label, '▶ Продолжить');
      _expectButtons(b, const _Expect(start: true));
    });

    test('Все завершили участие — активна «Завершить задание»', () {
      final b = sep(
        taskStatus: TaskStatus.inProgress,
        rowState: UserRunState.finished,
        productionStarted: true,
        participated: true,
        allPerformersFinished: true,
      );
      expect(b.finishTask.visible, isTrue);
      _expectButtons(b, const _Expect(start: true, finishTask: true));
    });

    test('Пока кто-то работает — «Завершить задание» выключена', () {
      final b = sep(
        taskStatus: TaskStatus.inProgress,
        rowState: UserRunState.finished,
        productionStarted: true,
        participated: true,
        allPerformersFinished: true,
        anyUserActive: true,
      );
      expect(b.finishTask.enabled, isFalse);
    });

    test('Задание окончательно завершено — всё выключено', () {
      final b = sep(
        taskStatus: TaskStatus.completed,
        rowState: UserRunState.finished,
        productionStarted: true,
        participated: true,
        allPerformersFinished: true,
      );
      expect(b.phase, TaskRowPhase.completed);
      _expectButtons(b, const _Expect());
    });

    test('«Пересмена» в этом режиме не показывается вообще', () {
      for (final state in UserRunState.values) {
        final b = sep(
          taskStatus: TaskStatus.inProgress,
          rowState: state,
          productionStarted: true,
          participated: true,
        );
        expect(b.shift.visible, isFalse, reason: 'состояние $state');
        expect(b.shift.enabled, isFalse, reason: 'состояние $state');
      }
    });

    test('Помощников в этом режиме нет', () {
      final b = sep(
        taskStatus: TaskStatus.inProgress,
        rowState: UserRunState.active,
        productionStarted: true,
        participated: true,
      );
      expect(b.helpers.visible, isFalse);
    });
  });

  group('Регрессы', () {
    test(
        'исходный баг: на новом этапе завершение выключено в обоих режимах',
        () {
      for (final mode in [ExecutionMode.joint, ExecutionMode.separate]) {
        for (final hasMachine in [true, false]) {
          final b = build(
            mode: mode,
            hasMachine: hasMachine,
            taskStatus: TaskStatus.waiting,
            productionStarted: false,
            participated: false,
          );
          expect(b.finish.enabled, isFalse,
              reason: 'режим $mode, станок $hasMachine');
          expect(b.finishTask.enabled, isFalse,
              reason: 'режим $mode, станок $hasMachine');
        }
      }
    });

    test('незакрытая наладка на паузе не даёт запустить производство', () {
      final b = build(
        taskStatus: TaskStatus.paused,
        rowState: UserRunState.paused,
        hasMachine: true,
        setupPendingForStage: true,
        setupUnfinishedForRow: true,
        participated: true,
      );
      expect(b.start.enabled, isFalse);
      expect(b.setup.enabled, isTrue);
      expect(b.setup.label, 'Продолжить наладку');
    });

    test('незакрытая наладка с проблемой не даёт запустить производство', () {
      final b = build(
        taskStatus: TaskStatus.problem,
        rowState: UserRunState.problem,
        hasMachine: true,
        setupPendingForStage: true,
        setupUnfinishedForRow: true,
        participated: true,
      );
      expect(b.start.enabled, isFalse);
      expect(b.setup.enabled, isTrue);
    });

    test('чужая незакрытая наладка не даёт начать свою', () {
      final b = build(
        hasMachine: true,
        setupPendingForStage: true,
        setupUnfinishedForRow: false,
      );
      expect(b.setup.visible, isTrue);
      expect(b.setup.enabled, isFalse);
    });

    test('«Начать наладку» подчиняется внешним запретам старта', () {
      final b = build(hasMachine: true, startBlockedExternally: true);
      expect(b.setup.enabled, isFalse);
      expect(b.start.enabled, isFalse);
    });

    test('помощниками нельзя управлять на завершённом этапе', () {
      final b = build(
        taskStatus: TaskStatus.completed,
        rowState: UserRunState.finished,
        productionStarted: true,
        participated: true,
      );
      expect(b.helpers.enabled, isFalse);
    });

    test('запрос в полёте выключает соответствующую кнопку', () {
      expect(build(startInFlight: true).start.enabled, isFalse);
      expect(
        build(hasMachine: true, setupInFlight: true).setup.enabled,
        isFalse,
      );
    });

    test('не полноправный исполнитель (помощник) кнопок не получает', () {
      final b = build(
        taskStatus: TaskStatus.inProgress,
        rowState: UserRunState.active,
        isAssignee: false,
        isOwner: false,
        productionStarted: true,
        participated: true,
      );
      _expectButtons(b, const _Expect(shift: true));
    });

    test('без участия в этапе завершение выключено', () {
      final b = build(
        taskStatus: TaskStatus.inProgress,
        rowState: UserRunState.active,
        productionStarted: true,
        participated: false,
      );
      expect(b.finish.enabled, isFalse);
    });
  });
}
