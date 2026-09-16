import 'package:flutter_test/flutter_test.dart';
import 'package:sheet_clone/modules/tasks/helper_interval_rules.dart';
import 'package:sheet_clone/modules/tasks/task_buttons_state.dart'
    show ExecutionMode;
import 'package:sheet_clone/modules/tasks/task_model.dart';

/// Помощника добавляют посреди уже идущего этапа. Без собственного интервала
/// его время в аналитике сводилось к минутным fallback-событиям количества:
/// «1 мин» и скорость в десятки тысяч штук в минуту, а смена не набиралась.
TaskTimeEvent _event({
  required String userId,
  required TaskTimeType type,
  required DateTime start,
  DateTime? end,
}) {
  return TaskTimeEvent(
    id: '$userId-${start.millisecondsSinceEpoch}',
    type: type,
    startTime: start,
    endTime: end,
    initiatedBy: userId,
    subjectUserId: userId,
    taskId: 'task-1',
    workplaceId: 'wp1',
    participantsSnapshot: const <String>[],
  );
}

void main() {
  final start = DateTime(2026, 6, 3, 8);

  test('этап идёт — помощник получает интервал того же типа', () {
    final decision = decideHelperInterval(
      assignees: const ['main', 'helper'],
      timeEvents: [
        _event(userId: 'main', type: TaskTimeType.production, start: start),
      ],
      helperId: 'helper',
    );

    expect(decision.shouldOpen, isTrue);
    expect(decision.type, TaskTimeType.production);
  });

  test('этап на паузе — помощнику пауза, а не производство', () {
    final decision = decideHelperInterval(
      assignees: const ['main', 'helper'],
      timeEvents: [
        _event(
          userId: 'main',
          type: TaskTimeType.production,
          start: start,
          end: start.add(const Duration(hours: 1)),
        ),
        _event(
          userId: 'main',
          type: TaskTimeType.pause,
          start: start.add(const Duration(hours: 1)),
        ),
      ],
      helperId: 'helper',
    );

    expect(decision.shouldOpen, isTrue);
    expect(decision.type, TaskTimeType.pause,
        reason: 'иначе помощнику капало бы рабочее время на стоящем станке');
  });

  test('этап не начат — интервал не нужен', () {
    final decision = decideHelperInterval(
      assignees: const ['main', 'helper'],
      timeEvents: const [],
      helperId: 'helper',
    );

    expect(decision.shouldOpen, isFalse);
  });

  test('этап завершён — интервал не нужен', () {
    final decision = decideHelperInterval(
      assignees: const ['main', 'helper'],
      timeEvents: [
        _event(
          userId: 'main',
          type: TaskTimeType.production,
          start: start,
          end: start.add(const Duration(hours: 2)),
        ),
      ],
      helperId: 'helper',
    );

    expect(decision.shouldOpen, isFalse);
  });

  test('у помощника уже есть открытый интервал — второй не заводим', () {
    final decision = decideHelperInterval(
      assignees: const ['main', 'helper'],
      timeEvents: [
        _event(userId: 'main', type: TaskTimeType.production, start: start),
        _event(userId: 'helper', type: TaskTimeType.production, start: start),
      ],
      helperId: 'helper',
    );

    expect(decision.shouldOpen, isFalse,
        reason: 'два открытых интервала удвоили бы время');
  });

  test('основной исполнитель сам себе не помощник', () {
    final decision = decideHelperInterval(
      assignees: const ['main', 'helper'],
      timeEvents: [
        _event(userId: 'main', type: TaskTimeType.production, start: start),
      ],
      helperId: 'main',
    );

    expect(decision.shouldOpen, isFalse);
  });

  test('без исполнителей решения нет', () {
    final decision = decideHelperInterval(
      assignees: const [],
      timeEvents: [
        _event(userId: 'main', type: TaskTimeType.production, start: start),
      ],
      helperId: 'helper',
    );

    expect(decision.shouldOpen, isFalse);
  });

  test('берётся последний открытый интервал основного', () {
    final decision = decideHelperInterval(
      assignees: const ['main', 'helper'],
      timeEvents: [
        _event(
          userId: 'main',
          type: TaskTimeType.production,
          start: start,
          end: start.add(const Duration(minutes: 30)),
        ),
        _event(
          userId: 'main',
          type: TaskTimeType.problem,
          start: start.add(const Duration(minutes: 30)),
        ),
      ],
      helperId: 'helper',
    );

    expect(decision.type, TaskTimeType.problem);
  });
  group('кому рассылать интервал бригады', () {
    // Регресс заказа ЗК-2026.08.26-1: пауза «Обед» разошлась по устаревшему
    // списку из четырёх человек, и двоим последним производственный интервал
    // не закрылся — он тянулся через час обеда, и доля вышла вдвое больше.
    ExecutionMode? joint(String _) => ExecutionMode.joint;

    test('все, кроме основного исполнителя', () {
      expect(
        jointHelperIds(
          assignees: const ['owner', 'a', 'b', 'c', 'd', 'e'],
          execModeOf: joint,
        ),
        ['a', 'b', 'c', 'd', 'e'],
      );
    });

    test('присоединившиеся последними не теряются', () {
      // Ровно тот случай: список вырос уже после отрисовки экрана.
      final fresh = ['owner', 'a', 'b', 'c', 'late1', 'late2'];
      final helpers = jointHelperIds(assignees: fresh, execModeOf: joint);
      expect(helpers, contains('late1'));
      expect(helpers, contains('late2'));
      expect(helpers, hasLength(5));
    });

    test('отдельные исполнители в рассылку не идут', () {
      // У них своя кнопка и свой интервал: чужая пауза их останавливать
      // не должна.
      expect(
        jointHelperIds(
          assignees: const ['owner', 'joint1', 'solo', 'joint2'],
          execModeOf: (id) =>
              id == 'solo' ? ExecutionMode.separate : ExecutionMode.joint,
        ),
        ['joint1', 'joint2'],
      );
    });

    test('дубли в assignees не задваивают интервал', () {
      expect(
        jointHelperIds(
          assignees: const ['owner', 'a', 'a', 'owner'],
          execModeOf: joint,
        ),
        ['a'],
      );
    });

    test('этап без исполнителей и этап из одного человека', () {
      expect(jointHelperIds(assignees: const [], execModeOf: joint), isEmpty);
      expect(
        jointHelperIds(assignees: const ['owner'], execModeOf: joint),
        isEmpty,
      );
    });

    test('режим неизвестен — участник остаётся в бригаде', () {
      // Отсутствие записи exec_mode не повод лишать человека паузы: молча
      // выкинуть его из рассылки — это ровно та ошибка, что уже случилась.
      expect(
        jointHelperIds(
          assignees: const ['owner', 'a'],
          execModeOf: (_) => null,
        ),
        ['a'],
      );
    });
  });
}
