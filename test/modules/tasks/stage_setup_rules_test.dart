import 'package:flutter_test/flutter_test.dart';
import 'package:sheet_clone/modules/tasks/stage_setup_rules.dart';

/// Реальные метки времени, чтобы порядок читался глазами.
const int day1Morning = 1757301039000; // 08.09 08:30
const int day1Evening = 1757342384000; // 08.09 19:59
const int day2Morning = 1757387263000; // 09.09 08:07
const int day2Setup = 1757387282000; // 09.09 08:08
const int day2Evening = 1757418000000; // 09.09 16:40

StageSetupState _state({
  Map<String, int> starts = const {},
  Map<String, int> dones = const {},
  List<int> production = const [],
}) =>
    StageSetupState(
      lastStartByUser: starts,
      lastDoneByUser: dones,
      productionStarts: production,
    );

void main() {
  group('своя наладка', () {
    test('начал и не закрыл — наладка висит', () {
      final state = _state(starts: {'u1': day1Morning});
      expect(state.unfinishedFor('u1'), isTrue);
      expect(state.pendingForStage, isTrue);
    });

    test('закрыл сам — наладка закрыта', () {
      final state = _state(
        starts: {'u1': day1Morning},
        dones: {'u1': day1Evening},
      );
      expect(state.unfinishedFor('u1'), isFalse);
      expect(state.pendingForStage, isFalse);
    });

    test('новая наладка после старого закрытия снова висит', () {
      final state = _state(
        starts: {'u1': day2Morning},
        dones: {'u1': day1Evening},
      );
      expect(state.unfinishedFor('u1'), isTrue);
    });

    test('наладку не начинали — ничего не висит', () {
      expect(_state().unfinishedFor('u1'), isFalse);
      expect(_state().pendingForStage, isFalse);
      expect(StageSetupState.empty.pendingForStage, isFalse);
    });
  });

  group('запуск тиража закрывает наладку', () {
    test('случай Вуколова: наладку начал один, закрыл сменщик', () {
      // 08.09 Вуколов начал наладку и ушёл на пересмену.
      // 09.09 Жылкыбай поднял этап, закрыл наладку собой и пустил тираж.
      final state = _state(
        starts: {'vukolov': day1Morning, 'zhylkybai': day2Morning},
        dones: {'zhylkybai': day2Setup},
        production: [day2Setup],
      );

      expect(state.unfinishedFor('vukolov'), isFalse,
          reason: 'станок пошёл в тираж — налаживать больше нечего');
      expect(state.unfinishedFor('zhylkybai'), isFalse);
      expect(state.pendingForStage, isFalse,
          reason: 'иначе этап запирается наглухо, как 09.09 на «Фри»');
    });

    test('тираж до начала наладки её не закрывает', () {
      // Этап перезапустили: производство шло, потом станок снова налаживают.
      final state = _state(
        starts: {'u1': day2Evening},
        production: [day2Setup],
      );
      expect(state.unfinishedFor('u1'), isTrue);
    });

    test('берётся самый поздний запуск тиража, а не первый', () {
      final state = _state(
        starts: {'u1': day2Morning},
        production: [day1Morning, day2Evening],
      );
      expect(state.unfinishedFor('u1'), isFalse);
    });

    test('свой setup_done важнее — даже без тиража', () {
      final state = _state(
        starts: {'u1': day1Morning},
        dones: {'u1': day2Morning},
      );
      expect(state.unfinishedFor('u1'), isFalse);
    });
  });

  group('раздельный режим', () {
    test('чужой setup_done чужую наладку не закрывает', () {
      // Двое налаживают свои станки: один закончил, второй ещё нет.
      final state = _state(
        starts: {'u1': day1Morning, 'u2': day1Morning},
        dones: {'u1': day1Evening},
      );
      expect(state.unfinishedFor('u1'), isFalse);
      expect(state.unfinishedFor('u2'), isTrue,
          reason: 'у каждого своя наладка, пока тираж не пошёл');
      expect(state.pendingForStage, isTrue);
    });

    test('кто именно не закрыл — видно поимённо', () {
      final state = _state(
        starts: {'u1': day1Morning, 'u2': day1Morning, 'u3': day1Morning},
        dones: {'u1': day1Evening},
      );
      expect(state.usersWithUnfinishedSetup, containsAll(['u2', 'u3']));
      expect(state.usersWithUnfinishedSetup, isNot(contains('u1')));
    });

    test('тираж закрывает наладку сразу всем', () {
      final state = _state(
        starts: {'u1': day1Morning, 'u2': day1Morning},
        production: [day2Morning],
      );
      expect(state.usersWithUnfinishedSetup, isEmpty);
      expect(state.pendingForStage, isFalse);
    });
  });

  test('о незнакомом сотруднике ничего не висит', () {
    final state = _state(starts: {'u1': day1Morning});
    expect(state.unfinishedFor('кто-то другой'), isFalse);
  });
}
