import 'package:flutter_test/flutter_test.dart';
import 'package:sheet_clone/modules/tasks/stage_sequence_utils.dart';

void main() {
  test('normalizeStageSequence removes mirrored duplicate tail', () {
    final normalized = normalizeStageSequence(['a', 'b', 'c', 'c', 'b', 'a']);
    expect(normalized, ['a', 'b', 'c']);
  });

  test('normalizeStageSequence keeps first occurrence order', () {
    final normalized = normalizeStageSequence(['  a ', 'b', 'a', '', 'c', 'b']);
    expect(normalized, ['a', 'b', 'c']);
  });

  test('cardboard cutting stage can start when previous stages are pending', () {
    final canStart = isFirstPendingStageInOrder(
      orderId: 'order-1',
      currentStageId: kCardboardCuttingStageId,
      stageStates: const [
        PendingStageState(stageId: 'previous-stage', completed: false),
        PendingStageState(
          stageId: kCardboardCuttingStageId,
          completed: false,
        ),
      ],
      orderedStages: const ['previous-stage', kCardboardCuttingStageId],
    );

    expect(canStart, isTrue);
  });

  test('ordinary stages remain blocked until previous stages are completed', () {
    final canStart = isFirstPendingStageInOrder(
      orderId: 'order-1',
      currentStageId: 'ordinary-stage',
      stageStates: const [
        PendingStageState(stageId: 'previous-stage', completed: false),
        PendingStageState(stageId: 'ordinary-stage', completed: false),
      ],
      orderedStages: const ['previous-stage', 'ordinary-stage'],
    );

    expect(canStart, isFalse);
  });

  test('cardboard cutting stage is available when first in order sequence', () {
    final canStart = isFirstPendingStageInOrder(
      orderId: 'order-1',
      currentStageId: kCardboardCuttingStageId,
      stageStates: const [
        PendingStageState(
          stageId: kCardboardCuttingStageId,
          completed: false,
        ),
        PendingStageState(stageId: 'next-stage', completed: false),
      ],
      orderedStages: const [kCardboardCuttingStageId, 'next-stage'],
    );

    expect(canStart, isTrue);
  });

  test('cardboard cutting stage is available when last in order sequence', () {
    final canStart = isFirstPendingStageInOrder(
      orderId: 'order-1',
      currentStageId: kCardboardCuttingStageId,
      stageStates: const [
        PendingStageState(stageId: 'previous-stage', completed: false),
        PendingStageState(stageId: 'middle-stage', completed: false),
        PendingStageState(
          stageId: kCardboardCuttingStageId,
          completed: false,
        ),
      ],
      orderedStages: const [
        'previous-stage',
        'middle-stage',
        kCardboardCuttingStageId,
      ],
    );

    expect(canStart, isTrue);
  });

  test('second stage is available after first stage has started', () {
    final canStart = isFirstPendingStageInOrder(
      orderId: 'order-1',
      currentStageId: 'stage-2',
      stageStates: const [
        PendingStageState(
          stageId: 'stage-1',
          completed: false,
          started: true,
        ),
        PendingStageState(stageId: 'stage-2', completed: false),
      ],
      orderedStages: const ['stage-1', 'stage-2', 'stage-3'],
    );

    expect(canStart, isTrue);
  });

  test('third stage remains blocked while second stage is waiting', () {
    final canStart = isFirstPendingStageInOrder(
      orderId: 'order-1',
      currentStageId: 'stage-3',
      stageStates: const [
        PendingStageState(
          stageId: 'stage-1',
          completed: false,
          started: true,
        ),
        PendingStageState(stageId: 'stage-2', completed: false),
        PendingStageState(stageId: 'stage-3', completed: false),
      ],
      orderedStages: const ['stage-1', 'stage-2', 'stage-3'],
    );

    expect(canStart, isFalse);
  });

  test('problem stage opens the next stage', () {
    final canStart = isFirstPendingStageInOrder(
      orderId: 'order-1',
      currentStageId: 'stage-2',
      stageStates: const [
        PendingStageState(
          stageId: 'stage-1',
          completed: false,
          problem: true,
        ),
        PendingStageState(stageId: 'stage-2', completed: false),
      ],
      orderedStages: const ['stage-1', 'stage-2'],
    );

    expect(canStart, isTrue);
  });
}
