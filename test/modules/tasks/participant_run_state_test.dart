import 'package:flutter_test/flutter_test.dart';
import 'package:sheet_clone/modules/tasks/stage_participant_output.dart';
import 'package:sheet_clone/modules/tasks/stage_status_colors.dart';
import 'package:sheet_clone/modules/tasks/task_buttons_state.dart'
    show UserRunState;
import 'package:sheet_clone/modules/tasks/task_model.dart';

int _seq = 0;

/// Незакрытый интервал: по нему видно, чем человек занят сейчас.
TaskComment openInterval(String userId, String type, {int startedAt = 5000}) =>
    TaskComment(
      id: 'e${_seq++}',
      type: 'time_event',
      text: '{"type":"$type","startTime":$startedAt,"subjectUserId":"$userId"}',
      userId: userId,
      timestamp: startedAt,
    );

TaskModel task({
  List<String> assignees = const [],
  List<TaskComment> comments = const [],
}) =>
    TaskModel(
      id: 't${_seq++}',
      orderId: 'order-1',
      stageId: 'stage-1',
      assignees: assignees,
      comments: comments,
    );

void main() {
  group('состояние участника', () {
    test('открытый производственный интервал — работает', () {
      final t = task(
        assignees: const ['a'],
        comments: [openInterval('a', 'production')],
      );
      expect(participantRunState([t], 'a'), UserRunState.active);
    });

    test('открытая пауза — на паузе', () {
      final t = task(
        assignees: const ['a'],
        comments: [openInterval('a', 'pause')],
      );
      expect(participantRunState([t], 'a'), UserRunState.paused);
    });

    test('открытая проблема — проблема', () {
      final t = task(
        assignees: const ['a'],
        comments: [openInterval('a', 'problem')],
      );
      expect(participantRunState([t], 'a'), UserRunState.problem);
    });

    test('без интервалов — не в работе', () {
      expect(
        participantRunState([task(assignees: const ['a'])], 'a'),
        UserRunState.idle,
      );
    });

    test('чужие интервалы на состояние не влияют', () {
      final t = task(
        assignees: const ['a', 'b'],
        comments: [openInterval('b', 'production')],
      );
      expect(participantRunState([t], 'a'), UserRunState.idle);
      expect(participantRunState([t], 'b'), UserRunState.active);
    });
  });

  group('приоритет между задачами этапа', () {
    test('РАБОТА перебивает проблему', () {
      // Главное правило подсветки имени: человек работает на одном рабочем
      // месте группы и стоит в проблеме на другом — имя горит «работает».
      final working = task(
        assignees: const ['a'],
        comments: [openInterval('a', 'production')],
      );
      final broken = task(
        assignees: const ['a'],
        comments: [openInterval('a', 'problem')],
      );
      expect(participantRunState([broken, working], 'a'), UserRunState.active);
      expect(participantRunState([working, broken], 'a'), UserRunState.active);
    });

    test('проблема перебивает паузу', () {
      final paused = task(
        assignees: const ['a'],
        comments: [openInterval('a', 'pause')],
      );
      final broken = task(
        assignees: const ['a'],
        comments: [openInterval('a', 'problem')],
      );
      expect(participantRunState([paused, broken], 'a'), UserRunState.problem);
    });

    test('любая активность перебивает «не в работе»', () {
      final idle = task(assignees: const ['a']);
      final paused = task(
        assignees: const ['a'],
        comments: [openInterval('a', 'pause')],
      );
      expect(participantRunState([idle, paused], 'a'), UserRunState.paused);
    });
  });

  group('состояние попадает в разбор этапа', () {
    test('каждый участник несёт своё состояние', () {
      final t = task(
        assignees: const ['a', 'b'],
        comments: [
          openInterval('a', 'production'),
          openInterval('b', 'pause'),
        ],
      );
      final output = stageOutputForTasks([t]);
      expect(output.participants[0].state, UserRunState.active);
      expect(output.participants[1].state, UserRunState.paused);
    });
  });

  group('цвета имени', () {
    test('палитра общая с этапом — не второй язык цветов', () {
      expect(
        participantRunStateColor(UserRunState.active),
        stageRunStatusColor(StageRunStatus.inProgress),
      );
      expect(
        participantRunStateColor(UserRunState.paused),
        stageRunStatusColor(StageRunStatus.paused),
      );
      expect(
        participantRunStateColor(UserRunState.problem),
        stageRunStatusColor(StageRunStatus.problem),
      );
      expect(
        participantRunStateColor(UserRunState.finished),
        stageRunStatusColor(StageRunStatus.completed),
      );
      expect(
        participantRunStateColor(UserRunState.idle),
        stageRunStatusColor(StageRunStatus.notStarted),
      );
    });

    test('все состояния различимы по цвету', () {
      final colors =
          UserRunState.values.map(participantRunStateColor).toSet();
      expect(colors.length, UserRunState.values.length);
    });

    test('у каждого состояния есть подпись', () {
      for (final state in UserRunState.values) {
        expect(participantRunStateLabel(state), isNotEmpty, reason: '$state');
      }
    });
  });
}
