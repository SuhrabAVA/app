import 'package:flutter_test/flutter_test.dart';
import 'package:sheet_clone/modules/tasks/task_process_state.dart';

void main() {
  group('Task process state machine', () {
    test(
        'SETUP -> handover -> B sees setup continued but not lit; start finishes setup',
        () {
      final initial = const TaskProcessState.initial();
      final setupStarted = onSetupPressed(initial, operatorId: 'A');
      final handoverPending = onHandoverPressed(setupStarted, operatorId: 'A');
      final confirmed = onHandoverPressed(handoverPending, operatorId: 'B');

      expect(confirmed.phase, ProcessPhase.setup);
      expect(confirmed.handoverState, HandoverState.none);
      expect(confirmed.currentOperatorId, 'B');
      expect(isSetupButtonLit(confirmed), isFalse);
      expect(canPressStart(confirmed, operatorId: 'B'), isTrue);

      final started = onStartPressed(confirmed, operatorId: 'B');
      expect(started.phase, ProcessPhase.running);
      expect(canPressSetup(started, operatorId: 'B'), isFalse);
    });

    test('RUNNING -> handover -> B has Start and Setup disabled', () {
      final running = onStartPressed(
        onSetupPressed(const TaskProcessState.initial(), operatorId: 'A'),
        operatorId: 'A',
      );
      final pending = onHandoverPressed(running, operatorId: 'A');
      final confirmed = onHandoverPressed(pending, operatorId: 'B');

      expect(confirmed.phase, ProcessPhase.running);
      expect(canPressStart(confirmed, operatorId: 'B'), isFalse);
      expect(canPressSetup(confirmed, operatorId: 'B'), isFalse);
    });

    test('PAUSED state is transferred through handover', () {
      final paused = onPausePressed(
        onStartPressed(
          onSetupPressed(const TaskProcessState.initial(), operatorId: 'A'),
          operatorId: 'A',
        ),
        operatorId: 'A',
      );
      final pending = onHandoverPressed(paused, operatorId: 'A');
      final confirmed = onHandoverPressed(pending, operatorId: 'B');

      expect(confirmed.pauseState, PauseState.paused);
      expect(canPressPause(confirmed, operatorId: 'B'), isFalse);
    });

    test(
        'SETUP + PAUSED + handover -> B sees pause disabled and state stays SETUP',
        () {
      final pausedSetup = onPausePressed(
        onSetupPressed(const TaskProcessState.initial(), operatorId: 'A'),
        operatorId: 'A',
      );
      final pending = onHandoverPressed(pausedSetup, operatorId: 'A');
      final confirmed = onHandoverPressed(pending, operatorId: 'B');

      expect(confirmed.phase, ProcessPhase.setup);
      expect(confirmed.pauseState, PauseState.paused);
      expect(canPressPause(confirmed, operatorId: 'B'), isFalse);
      expect(canPressSetup(confirmed, operatorId: 'B'), isFalse);
      expect(isSetupButtonLit(confirmed), isFalse);
    });
  });
}
