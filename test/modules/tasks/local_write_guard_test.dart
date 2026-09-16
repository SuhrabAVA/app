import 'package:flutter_test/flutter_test.dart';
import 'package:sheet_clone/modules/tasks/local_write_guard.dart';

class _Row {
  const _Row(this.id, this.value);

  final String id;
  final String value;

  @override
  String toString() => '$id=$value';
}

void main() {
  LocalWriteGuard<_Row> newGuard() =>
      LocalWriteGuard<_Row>(idOf: (row) => row.id);

  test('запись во время чтения переживает опоздавший перечит', () {
    // Ровно случай 16.09: перечит стартовал до пересмены, а вернулся после
    // неё — и вернул задачу в состояние «этап идёт, помощник на месте».
    final guard = newGuard();
    final token = guard.beginFetch();
    guard.record(const _Row('task-1', 'пересмена'));

    final merged = guard.reconcile(
      const [_Row('task-1', 'в работе'), _Row('task-2', 'в работе')],
      token,
    );

    expect(merged.first.value, 'пересмена');
    expect(merged.last.value, 'в работе', reason: 'чужие строки не трогаем');
  });

  test('запись до начала чтения перечит перекрывает', () {
    final guard = newGuard();
    guard.record(const _Row('task-1', 'локально'));
    final token = guard.beginFetch();

    final merged = guard.reconcile(const [_Row('task-1', 'с сервера')], token);

    expect(merged.single.value, 'с сервера');
    expect(guard.pendingCount, 0, reason: 'подтверждённая запись забывается');
  });

  test('последняя локальная версия побеждает предыдущие', () {
    final guard = newGuard();
    final token = guard.beginFetch();
    guard.record(const _Row('task-1', 'первая'));
    guard.record(const _Row('task-1', 'вторая'));

    final merged = guard.reconcile(const [_Row('task-1', 'с сервера')], token);

    expect(merged.single.value, 'вторая');
  });

  test('следующий перечит уже включает запись и отпускает её', () {
    final guard = newGuard();
    final first = guard.beginFetch();
    guard.record(const _Row('task-1', 'пересмена'));
    guard.reconcile(const [_Row('task-1', 'в работе')], first);
    expect(guard.pendingCount, 1);

    final second = guard.beginFetch();
    final merged =
        guard.reconcile(const [_Row('task-1', 'пересмена с сервера')], second);

    expect(merged.single.value, 'пересмена с сервера');
    expect(guard.pendingCount, 0);
  });

  test('строки, пропавшей из чтения, guard не воскрешает', () {
    final guard = newGuard();
    final token = guard.beginFetch();
    guard.record(const _Row('task-1', 'пересмена'));

    final merged = guard.reconcile(const [_Row('task-2', 'в работе')], token);

    expect(merged.length, 1);
    expect(merged.single.id, 'task-2');
  });

  test('forget снимает защиту', () {
    final guard = newGuard();
    final token = guard.beginFetch();
    guard.record(const _Row('task-1', 'пересмена'));
    guard.forget('task-1');

    final merged = guard.reconcile(const [_Row('task-1', 'в работе')], token);

    expect(merged.single.value, 'в работе');
  });
}
