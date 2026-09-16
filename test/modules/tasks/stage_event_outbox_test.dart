import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sheet_clone/modules/tasks/stage_event_outbox.dart';

/// Отправщик-заглушка: сценарий задаётся списком ответов на каждый ключ.
class _FakeSender {
  _FakeSender();

  /// Что вернуть на очередную попытку конкретного намерения.
  final Map<String, List<StageSendResult>> scripted =
      <String, List<StageSendResult>>{};

  /// Ответ по умолчанию, когда для ключа сценарий не задан.
  StageSendResult fallback = const StageSendResult.applied({'ok': true});

  final List<String> sent = <String>[];

  Future<StageSendResult> call(StageEventRequest request) async {
    sent.add(request.requestId);
    final queue = scripted[request.requestId];
    if (queue != null && queue.isNotEmpty) return queue.removeAt(0);
    return fallback;
  }
}

StageEventRequest _request({
  required String id,
  String taskId = 'task-1',
  String op = 'add_assignee',
  String userId = 'u1',
  int createdAt = 1750000000000,
  String? expectAssignee,
  String? label,
}) =>
    StageEventRequest(
      requestId: id,
      taskId: taskId,
      ops: [
        {'op': op, 'userId': userId}
      ],
      createdAtMillis: createdAt,
      expectAssignee: expectAssignee,
      label: label,
    );

void main() {
  const now = 1750000000000;

  group('выдержка между попытками', () {
    test('первая попытка ждёт две секунды, дальше реже', () {
      expect(StageEventOutbox.backoffMillis(1), 2000);
      expect(StageEventOutbox.backoffMillis(2), 5000);
      expect(StageEventOutbox.backoffMillis(3), 10000);
    });

    test('после исчерпания расписания держится максимум', () {
      expect(StageEventOutbox.backoffMillis(99),
          kStageRetryBackoffMillis.last);
    });
  });

  group('очередь', () {
    test('успешная отправка не оставляет ничего в очереди', () async {
      final sender = _FakeSender();
      final outbox = StageEventOutbox(sender: sender.call);
      await outbox.enqueue(_request(id: 'r1'), nowMillis: now);

      expect(outbox.pendingCount, 1);
      // Сразу после постановки срок ещё не пришёл: выдержка две секунды.
      expect(await outbox.flush(nowMillis: now), 0);
      expect(sender.sent, isEmpty);

      expect(await outbox.flush(nowMillis: now + 2000), 1);
      expect(outbox.pendingCount, 0);
    });

    test('обрыв связи оставляет намерение и увеличивает выдержку', () async {
      final sender = _FakeSender();
      sender.scripted['r1'] = [const StageSendResult.retry('нет связи')];
      final outbox = StageEventOutbox(sender: sender.call);
      await outbox.enqueue(_request(id: 'r1'), nowMillis: now);

      expect(await outbox.flush(nowMillis: now + 2000), 0);
      expect(outbox.pendingCount, 1);
      expect(outbox.pending.single.attempts, 2);
      // Следующая попытка — через пять секунд, а не через две.
      expect(outbox.pending.single.nextAttemptAtMillis, now + 2000 + 5000);

      expect(await outbox.flush(nowMillis: now + 2000 + 5000), 1);
      expect(outbox.pendingCount, 0);
    });

    test('ключ между попытками не меняется', () async {
      final sender = _FakeSender();
      sender.scripted['r1'] = [
        const StageSendResult.retry('нет связи'),
        const StageSendResult.retry('нет связи'),
      ];
      final outbox = StageEventOutbox(sender: sender.call);
      await outbox.enqueue(_request(id: 'r1'), nowMillis: now);

      await outbox.flush(nowMillis: now + 2000);
      await outbox.flush(nowMillis: now + 100000);
      await outbox.flush(nowMillis: now + 200000);

      expect(sender.sent, ['r1', 'r1', 'r1']);
    });

    test('отказ сервера не повторяется и объясняется человеку', () async {
      final sender = _FakeSender();
      sender.scripted['r1'] = [
        const StageSendResult.rejected('Сотрудник больше не назначен на этап.'),
      ];
      final rejected = <String>[];
      final outbox = StageEventOutbox(
        sender: sender.call,
        onRejected: (_, reason) => rejected.add(reason),
      );
      await outbox.enqueue(_request(id: 'r1'), nowMillis: now);

      expect(await outbox.flush(nowMillis: now + 2000), 0);
      expect(outbox.pendingCount, 0, reason: 'повторять отказ бессмысленно');
      expect(rejected, ['Сотрудник больше не назначен на этап.']);
      expect(sender.sent, ['r1']);
    });

    test('исключение из отправщика считается обрывом, а не отказом', () async {
      var calls = 0;
      final outbox = StageEventOutbox(sender: (request) async {
        calls += 1;
        if (calls == 1) throw StateError('сокет закрылся');
        return const StageSendResult.applied({'ok': true});
      });
      await outbox.enqueue(_request(id: 'r1'), nowMillis: now);

      await outbox.flush(nowMillis: now + 2000);
      expect(outbox.pendingCount, 1, reason: 'намерение нельзя терять');

      await outbox.flush(nowMillis: now + 100000);
      expect(outbox.pendingCount, 0);
    });

    test('ответ сервера передаётся наружу — экрану есть что показать',
        () async {
      final sender = _FakeSender();
      sender.fallback = const StageSendResult.applied({
        'assignees': ['u1'],
        'comments': [],
      });
      final applied = <Object?>[];
      final outbox = StageEventOutbox(
        sender: sender.call,
        onApplied: (_, payload) => applied.add(payload),
      );
      await outbox.enqueue(_request(id: 'r1'), nowMillis: now);
      await outbox.flush(nowMillis: now + 2000);

      expect(applied.single, isA<Map>());
      expect((applied.single as Map)['assignees'], ['u1']);
    });
  });

  group('порядок внутри задачи', () {
    test('второе намерение задачи ждёт, пока не пройдёт первое', () async {
      final sender = _FakeSender();
      sender.scripted['r1'] = [const StageSendResult.retry('нет связи')];
      final outbox = StageEventOutbox(sender: sender.call);
      await outbox.enqueue(_request(id: 'r1', op: 'add_assignee'),
          nowMillis: now);
      await outbox.enqueue(_request(id: 'r2', op: 'close_interval'),
          nowMillis: now);

      await outbox.flush(nowMillis: now + 2000);
      expect(sender.sent, ['r1'],
          reason: 'закрытие интервала не должно обгонять начало этапа');
      expect(outbox.pendingCount, 2);

      await outbox.flush(nowMillis: now + 100000);
      expect(sender.sent, ['r1', 'r1', 'r2']);
      expect(outbox.pendingCount, 0);
    });

    test('после успеха первого второе уходит в том же проходе', () async {
      final sender = _FakeSender();
      final outbox = StageEventOutbox(sender: sender.call);
      await outbox.enqueue(_request(id: 'r1'), nowMillis: now);
      await outbox.enqueue(_request(id: 'r2', op: 'close_interval'),
          nowMillis: now);

      expect(await outbox.flush(nowMillis: now + 2000), 2);
      expect(sender.sent, ['r1', 'r2']);
    });

    test('застрявшая задача не держит остальные', () async {
      final sender = _FakeSender();
      sender.scripted['r1'] = [const StageSendResult.retry('нет связи')];
      final outbox = StageEventOutbox(sender: sender.call);
      await outbox.enqueue(_request(id: 'r1', taskId: 'task-1'),
          nowMillis: now);
      await outbox.enqueue(_request(id: 'r2', taskId: 'task-2'),
          nowMillis: now);

      expect(await outbox.flush(nowMillis: now + 2000), 1);
      expect(sender.sent, ['r1', 'r2']);
      expect(outbox.pending.single.requestId, 'r1');
    });
  });

  group('повторное нажатие кнопки', () {
    test('то же намерение переиспользует прежний ключ', () async {
      final outbox = StageEventOutbox(sender: (_) async {
        return const StageSendResult.retry('нет связи');
      });
      final first = _request(id: 'r1', userId: 'u1');
      await outbox.enqueue(first, nowMillis: now);

      // Второе нажатие: тот же этап, та же операция — ключ должен совпасть.
      final second = _request(id: 'ignored', userId: 'u1');
      expect(outbox.pendingIdFor(second), 'r1');

      // Другая операция — другое намерение, свой ключ.
      final other = _request(id: 'ignored', op: 'close_interval');
      expect(outbox.pendingIdFor(other), isNull);
    });

    test('одинаковый ключ не задваивает строку в очереди', () async {
      final outbox = StageEventOutbox(sender: (_) async {
        return const StageSendResult.retry('нет связи');
      });
      await outbox.enqueue(_request(id: 'r1'), nowMillis: now);
      await outbox.enqueue(_request(id: 'r1'), nowMillis: now);
      expect(outbox.pendingCount, 1);
    });

    test('отпечаток учитывает ожидаемого исполнителя', () {
      final a = _request(id: 'r1', expectAssignee: 'u1');
      final b = _request(id: 'r2', expectAssignee: 'u2');
      expect(a.fingerprint == b.fingerprint, isFalse);
    });
  });

  group('хранилище', () {
    test('очередь переживает перезапуск планшета', () async {
      final store = MemoryStageOutboxStore();
      final first = StageEventOutbox(
        sender: (_) async => const StageSendResult.retry('нет связи'),
        store: store,
      );
      await first.enqueue(
        _request(id: 'r1', label: 'Пересмена'),
        nowMillis: now,
      );
      await first.flush(nowMillis: now + 2000);

      // Новый запуск приложения — новая очередь, тот же диск.
      final sender = _FakeSender();
      final second = StageEventOutbox(sender: sender.call, store: store);
      await second.load();

      expect(second.pendingCount, 1);
      final restored = second.pending.single;
      expect(restored.requestId, 'r1');
      expect(restored.label, 'Пересмена');
      expect(restored.attempts, 2, reason: 'счётчик попыток тоже сохраняется');

      expect(await second.flush(nowMillis: now + 1000000), 1);
      expect(sender.sent, ['r1']);
    });

    test('битая запись не роняет остальную очередь', () async {
      final store = MemoryStageOutboxStore();
      await store.write(jsonEncode({
        'version': 1,
        'requests': [
          {'taskId': 'task-1'}, // нет ключа
          {'requestId': 'r2', 'taskId': 'task-1', 'ops': []}, // нет операций
          _request(id: 'r3').toJson(),
        ],
      }));
      final outbox = StageEventOutbox(
        sender: (_) async => const StageSendResult.applied(null),
        store: store,
      );
      await outbox.load();

      expect(outbox.pending.map((r) => r.requestId), ['r3']);
    });

    test('мусор вместо json не роняет загрузку', () async {
      final store = MemoryStageOutboxStore();
      await store.write('не json');
      final outbox = StageEventOutbox(
        sender: (_) async => const StageSendResult.applied(null),
        store: store,
      );
      await outbox.load();
      expect(outbox.pendingCount, 0);
    });

    test('недоступное хранилище не мешает работать', () async {
      final outbox = StageEventOutbox(
        sender: (_) async => const StageSendResult.applied(null),
        store: _BrokenStore(),
      );
      await outbox.load();
      await outbox.enqueue(_request(id: 'r1'), nowMillis: now);
      expect(outbox.pendingCount, 1);
      expect(await outbox.flush(nowMillis: now + 2000), 1);
    });
  });

  group('срок жизни', () {
    test('намерение старше недели выбрасывается с объяснением', () async {
      final sender = _FakeSender();
      final rejected = <String>[];
      final outbox = StageEventOutbox(
        sender: sender.call,
        onRejected: (_, reason) => rejected.add(reason),
      );
      await outbox.enqueue(_request(id: 'r1', createdAt: now),
          nowMillis: now);

      final week = kStageRequestMaxAge.inMilliseconds;
      expect(await outbox.flush(nowMillis: now + week + 1), 0);
      expect(outbox.pendingCount, 0);
      expect(sender.sent, isEmpty,
          reason: 'ключ на сервере уже удалён — повтор задвоил бы запись');
      expect(rejected.single, contains('дольше недели'));
    });

    test('внутри срока намерение продолжает отправляться', () async {
      final sender = _FakeSender();
      final outbox = StageEventOutbox(sender: sender.call);
      await outbox.enqueue(_request(id: 'r1', createdAt: now),
          nowMillis: now);

      final week = kStageRequestMaxAge.inMilliseconds;
      expect(await outbox.flush(nowMillis: now + week - 1000), 1);
      expect(sender.sent, ['r1']);
    });
  });

  test('пустая очередь ничего не отправляет', () async {
    final sender = _FakeSender();
    final outbox = StageEventOutbox(sender: sender.call);
    expect(await outbox.flush(nowMillis: now), 0);
    expect(sender.sent, isEmpty);
    expect(outbox.nextAttemptAtMillis, isNull);
  });

  test('nextAttemptAtMillis показывает ближайший срок', () async {
    final outbox = StageEventOutbox(
      sender: (_) async => const StageSendResult.retry('нет связи'),
    );
    await outbox.enqueue(_request(id: 'r1'), nowMillis: now);
    await outbox.enqueue(_request(id: 'r2', taskId: 'task-2'),
        nowMillis: now + 500);
    expect(outbox.nextAttemptAtMillis, now + 2000);
  });
}

class _BrokenStore implements StageOutboxStore {
  @override
  Future<String?> read() async => throw StateError('нет доступа к диску');

  @override
  Future<void> write(String value) async =>
      throw StateError('нет доступа к диску');
}
