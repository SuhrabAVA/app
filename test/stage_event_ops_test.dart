import 'package:flutter_test/flutter_test.dart';
import 'package:sheet_clone/modules/tasks/stage_event_ops.dart';

List<String> _kinds(List<Map<String, dynamic>> ops) =>
    ops.map((op) => op['op'] as String).toList();

List<String> _commentTypes(List<Map<String, dynamic>> ops) => ops
    .where((op) => op['op'] == 'comment')
    .map((op) => op['type'] as String)
    .toList();

Map<String, dynamic>? _firstWhereOrNull(
  List<Map<String, dynamic>> ops,
  bool Function(Map<String, dynamic>) test,
) {
  for (final op in ops) {
    if (test(op)) return op;
  }
  return null;
}

void main() {
  group('stageStart', () {
    test('назначение попадает в тот же список, что старт и интервал', () {
      // Регрессия «Жанна не может начать заказ, хотя начинала»: назначение
      // уходило отдельным запросом, терялось на сбойной сети, и сотрудник
      // оставался с интервалом, но без строки в assignees — экран переставал
      // показывать ему кнопки вообще.
      final ops = StageEventPlans.stageStart(
        userId: 'zhanna',
        workplaceId: 'wp-1',
        participants: const ['zhanna'],
        alreadyAssigned: false,
        isResume: false,
        personalExecutionModeCode: 'separate',
        intervalExecutionModeCode: 'separate',
      );

      expect(_kinds(ops).first, 'add_assignee',
          reason: 'назначение должно быть первой операцией');
      expect(_kinds(ops), contains('open_interval'));
      expect(_commentTypes(ops), ['exec_mode', 'start']);
    });

    test('уже назначенному сотруднику назначение не дублируется', () {
      final ops = StageEventPlans.stageStart(
        userId: 'zhanna',
        workplaceId: 'wp-1',
        participants: const ['zhanna'],
        alreadyAssigned: true,
        isResume: false,
      );

      expect(_kinds(ops), isNot(contains('add_assignee')));
    });

    test('возобновление пишет resume, а не start', () {
      final ops = StageEventPlans.stageStart(
        userId: 'zhanna',
        workplaceId: 'wp-1',
        participants: const ['zhanna'],
        alreadyAssigned: true,
        isResume: true,
      );

      expect(_commentTypes(ops), ['resume']);
    });

    test('завершение наладки идёт перед отметкой старта', () {
      final ops = StageEventPlans.stageStart(
        userId: 'ahtam',
        workplaceId: 'wp-1',
        participants: const ['ahtam'],
        alreadyAssigned: true,
        isResume: false,
        setupDoneOps: StageEventPlans.setupDone(
          userId: 'ahtam',
          setupDoneText: 'Завершил(а) настройку станка',
          helperIds: const [],
        ),
      );

      expect(_commentTypes(ops), ['setup_done', 'start']);
      final closeIndex = ops.indexWhere((op) => op['op'] == 'close_interval');
      final openIndex = ops.indexWhere((op) => op['op'] == 'open_interval');
      expect(closeIndex, lessThan(openIndex),
          reason: 'интервал наладки закрывается до открытия производственного');
    });

    test('в совместном режиме помощники получают свои интервалы', () {
      final ops = StageEventPlans.stageStart(
        userId: 'owner',
        workplaceId: 'wp-1',
        participants: const ['owner', 'helper-1', 'helper-2'],
        alreadyAssigned: true,
        isResume: false,
        helperIds: const ['helper-1', 'helper-2'],
      );

      final intervals =
          ops.where((op) => op['op'] == 'open_interval').toList();
      expect(intervals, hasLength(3));
      expect(intervals[1]['helperId'], 'helper-1');
      expect(intervals[2]['helperId'], 'helper-2');
    });
  });

  group('shiftPause', () {
    test('записи пересмены лежат в одном списке с интервалом', () {
      // Регрессия «нет записей по пересмене»: у Ахтама 02.09 долетел только
      // интервал shift_change, а shift_pause_state и shift_pause — нет.
      final ops = StageEventPlans.shiftPause(
        userId: 'ahtam',
        workplaceId: 'wp-1',
        participants: const ['ahtam'],
        resumeState: 'setup',
        helpersToRelease: const [],
      );

      expect(_commentTypes(ops), ['shift_pause_state', 'shift_pause']);
      final interval =
          _firstWhereOrNull(ops, (op) => op['op'] == 'open_interval');
      expect(interval, isNotNull);
      expect(interval!['type'], StageIntervalType.shiftChange);
      expect(interval['subject'], 'ahtam');
    });

    test('количество отрезка пишется до всего остального', () {
      final ops = StageEventPlans.shiftPause(
        userId: 'owner',
        workplaceId: 'wp-1',
        participants: const ['owner'],
        resumeState: 'production',
        helpersToRelease: const [],
        quantityCommentType: 'quantity_team_total',
        quantityCommentText: '{"actual":100.0}',
      );

      expect(_commentTypes(ops).first, 'quantity_team_total');
    });

    test('снятый помощник не получает нового интервала', () {
      // Живой случай 15.09 («Ручка-склейка крученая»): помощнику закрывали
      // интервал, снимали его с этапа и тут же открывали ему интервал
      // пересмены. База не даёт снять исполнителя с открытым интервалом
      // (tasks_guard_active_assignees), и пересмена падала целиком —
      // получалось только после ручного удаления всех помощников.
      final ops = StageEventPlans.shiftPause(
        userId: 'owner',
        workplaceId: 'wp-1',
        participants: const ['owner', 'helper-1'],
        resumeState: 'production',
        helpersToRelease: const ['helper-1'],
      );

      final closeIndex = ops.indexWhere((op) =>
          op['op'] == 'close_interval' && op['subject'] == 'helper-1');
      final removeIndex = ops.indexWhere((op) =>
          op['op'] == 'remove_assignee' && op['userId'] == 'helper-1');

      expect(closeIndex, isNonNegative);
      expect(removeIndex, greaterThan(closeIndex));
      expect(
        ops.where((op) =>
            op['op'] == 'open_interval' && op['subject'] == 'helper-1'),
        isEmpty,
      );
      // Интервал пересмены остаётся только у того, кто её объявил.
      expect(
        ops.where((op) => op['op'] == 'open_interval').single['subject'],
        'owner',
      );
    });
  });

  group('shiftResume', () {
    test('пришедшая смена забирает этап себе и получает управление', () {
      // В совместном режиме кнопки доступны только assignees.first. Если
      // пришедшую смену просто дописать в конец списка, она останется без
      // единой доступной кнопки — ровно тот же тупик, что у Жанны.
      final ops = StageEventPlans.shiftResume(
        userId: 'baimurat',
        workplaceId: 'wp-1',
        participants: const ['baimurat'],
        intervalType: StageIntervalType.setup,
        resumeText: 'Пересмена: работа возобновлена',
        needsSetupStart: true,
      );

      expect(_kinds(ops).first, 'claim_stage');
      expect(ops.first['userId'], 'baimurat');
      expect(_commentTypes(ops), ['setup_start', 'shift_resume']);
    });

    test('интервалы прошлой смены закрываются до захвата этапа', () {
      // База не даёт снять с этапа человека с открытым интервалом
      // (tasks_guard_active_assignees), а claim_stage делает пришедшую смену
      // единственным исполнителем. Не закрыв интервал в этом же вызове,
      // возобновление упёрлось бы в защиту.
      final ops = StageEventPlans.shiftResume(
        userId: 'baimurat',
        workplaceId: 'wp-1',
        participants: const ['baimurat'],
        intervalType: StageIntervalType.production,
        resumeText: 'Пересмена: работа возобновлена',
        needsSetupStart: false,
        closeIntervalsFor: const ['ahtam', 'halit'],
      );

      final kinds = _kinds(ops);
      expect(kinds.take(2), ['close_interval', 'close_interval']);
      expect(kinds[2], 'claim_stage');
      expect(
        ops.take(2).map((op) => op['subject']),
        ['ahtam', 'halit'],
      );
    });

    test('сам возобновляющий и пустые id в закрытие не идут', () {
      // Свой интервал пришедшая смена открывает следующей же операцией —
      // закрывать его перед этим нечего.
      final ops = StageEventPlans.shiftResume(
        userId: 'baimurat',
        workplaceId: 'wp-1',
        participants: const ['baimurat'],
        intervalType: StageIntervalType.production,
        resumeText: 'Пересмена: работа возобновлена',
        needsSetupStart: false,
        closeIntervalsFor: const ['baimurat', '  ', 'ahtam'],
      );

      expect(_kinds(ops).first, 'close_interval');
      expect(ops.first['subject'], 'ahtam');
      expect(_kinds(ops).where((k) => k == 'close_interval').length, 1);
    });

    test('без незакрытых интервалов лишних операций нет', () {
      final ops = StageEventPlans.shiftResume(
        userId: 'baimurat',
        workplaceId: 'wp-1',
        participants: const ['baimurat'],
        intervalType: StageIntervalType.production,
        resumeText: 'Пересмена: работа возобновлена',
        needsSetupStart: false,
      );
      expect(_kinds(ops).first, 'claim_stage');
    });

    test('без наладки отметка setup_start не пишется', () {
      final ops = StageEventPlans.shiftResume(
        userId: 'baimurat',
        workplaceId: 'wp-1',
        participants: const ['baimurat'],
        intervalType: StageIntervalType.production,
        resumeText: 'Пересмена: работа возобновлена',
        needsSetupStart: false,
      );

      expect(_commentTypes(ops), ['shift_resume']);
    });
  });

  group('помощники', () {
    test('добавление помощника — одно назначение и одна отметка', () {
      final ops = StageEventPlans.addHelper(
        helperId: 'helper-1',
        actorId: 'owner',
        workplaceId: 'wp-1',
        participants: const ['owner', 'helper-1'],
        helperModeCode: 'joint',
        openIntervalType: StageIntervalType.production,
      );

      expect(_kinds(ops).first, 'add_assignee');
      expect(_commentTypes(ops), ['exec_mode', 'joined']);
      final interval =
          _firstWhereOrNull(ops, (op) => op['op'] == 'open_interval');
      expect(interval!['helperId'], 'helper-1');
    });

    test('на не начатом этапе интервал помощнику не открывается', () {
      final ops = StageEventPlans.addHelper(
        helperId: 'helper-1',
        actorId: 'owner',
        workplaceId: 'wp-1',
        participants: const ['owner', 'helper-1'],
      );

      expect(_kinds(ops), isNot(contains('open_interval')));
    });

    test('удаление помощника закрывает интервал до снятия назначения', () {
      final ops = StageEventPlans.removeHelper(
        helperId: 'helper-1',
        actorId: 'owner',
        helperName: 'Иван Иванов',
      );

      expect(_kinds(ops), ['close_interval', 'remove_assignee', 'comment']);
      expect(ops.first['note'], 'helper_removed');
    });
  });

  group('participantFinish', () {
    test('количество, отметка и закрытие интервала — одним списком', () {
      // Регрессия «количество записано дважды»: три отдельных вызова, первый
      // уходил в очередь повторов, второе нажатие писало количество ещё раз.
      final ops = StageEventPlans.participantFinish(
        userId: 'packer',
        quantityText: '{"actual":50}',
      );

      expect(_kinds(ops), ['comment', 'comment', 'close_interval']);
      expect(_commentTypes(ops), ['quantity_done', 'user_done']);
      expect(ops.every((op) => (op['userId'] ?? op['subject']) == 'packer'),
          isTrue);
    });

    test('количество идёт раньше отметки — сервер проверяет повтор по ней', () {
      final ops = StageEventPlans.participantFinish(
        userId: 'packer',
        quantityText: '12',
      );

      final qtyIndex = ops.indexWhere((op) => op['type'] == 'quantity_done');
      final doneIndex = ops.indexWhere((op) => op['type'] == 'user_done');
      expect(qtyIndex, lessThan(doneIndex));
      expect(ops[qtyIndex]['text'], '12');
    });
  });
}
