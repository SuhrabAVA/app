import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sheet_clone/modules/tasks/stage_status_colors.dart';

void main() {
  StageRunStatus resolve({
    bool finalized = false,
    bool anyProblem = false,
    bool anyActive = false,
    bool shiftPaused = false,
    bool hasPerformers = false,
    bool allPerformersFinished = false,
    bool anyPaused = false,
    bool started = false,
    bool availableToStart = false,
  }) =>
      resolveStageRunStatus(
        finalized: finalized,
        anyProblem: anyProblem,
        anyActive: anyActive,
        shiftPaused: shiftPaused,
        hasPerformers: hasPerformers,
        allPerformersFinished: allPerformersFinished,
        anyPaused: anyPaused,
        started: started,
        availableToStart: availableToStart,
      );

  group('приоритет статусов этапа с несколькими исполнителями', () {
    test('проблема перекрывает всё, даже чужую активную работу', () {
      expect(
        resolve(
          anyProblem: true,
          anyActive: true,
          anyPaused: true,
          hasPerformers: true,
          started: true,
        ),
        StageRunStatus.problem,
      );
    });

    test('один работает — этап в работе, паузы остальных не считаются', () {
      expect(
        resolve(
          anyActive: true,
          anyPaused: true,
          hasPerformers: true,
          allPerformersFinished: false,
          started: true,
        ),
        StageRunStatus.inProgress,
      );
    });

    test('все завершили участие, задание не закрыто — пересмена', () {
      // Ровно тот случай, из-за которого этап выглядел «на стопе»: люди
      // отметились «Завершить», но итоговую кнопку «Завершить задание» никто
      // не нажал. Работа стоит, а этап не закончен.
      expect(
        resolve(
          hasPerformers: true,
          allPerformersFinished: true,
          started: true,
        ),
        StageRunStatus.shiftChange,
      );
    });

    test('явная пересмена тоже оранжевая', () {
      expect(
        resolve(shiftPaused: true, hasPerformers: true, started: true),
        StageRunStatus.shiftChange,
      );
    });

    test('все на паузе — жёлтый', () {
      expect(
        resolve(anyPaused: true, hasPerformers: true, started: true),
        StageRunStatus.paused,
      );
    });

    test('завершён только по итоговой кнопке, и она сильнее всего', () {
      expect(
        resolve(finalized: true, anyProblem: true, anyActive: true),
        StageRunStatus.completed,
      );
    });
  });

  group('нетронутый этап', () {
    test('очередь дошла — светло-зелёный', () {
      expect(resolve(availableToStart: true), StageRunStatus.availableToStart);
    });

    test('очередь не дошла — серый', () {
      expect(resolve(), StageRunStatus.notStarted);
    });

    test('начатый, но брошенный этап показывается паузой, а не «не начат»', () {
      expect(resolve(started: true), StageRunStatus.paused);
    });
  });

  test('у каждого статуса свой цвет и подпись', () {
    final colors = <int>{};
    final labels = <String>{};
    for (final status in StageRunStatus.values) {
      colors.add(stageRunStatusColor(status).toARGB32());
      labels.add(stageRunStatusLabel(status));
    }
    expect(colors.length, StageRunStatus.values.length);
    expect(labels.length, StageRunStatus.values.length);
  });

  test('завершённый этап — обычный зелёный, а не тёмный', () {
    // Тёмно-зелёный (0xFF15803D) на планшете в цеху читался почти чёрным.
    final completed = stageRunStatusColor(StageRunStatus.completed);
    expect(completed, const Color(0xFF22C55E));
    // И всё же заметно темнее «доступен к началу», иначе два зелёных
    // сливались бы.
    final available = stageRunStatusColor(StageRunStatus.availableToStart);
    expect(completed.g, lessThan(available.g));
  });

  group('stageUnlocksNextStage', () {
    test('начатому этапу достаточно быть начатым — следующий открыт', () {
      for (final status in const [
        StageRunStatus.inProgress,
        StageRunStatus.paused,
        StageRunStatus.problem,
        StageRunStatus.shiftChange,
        StageRunStatus.completed,
      ]) {
        expect(stageUnlocksNextStage(status), isTrue, reason: '$status');
      }
    });

    test('нетронутый этап следующий не открывает', () {
      expect(stageUnlocksNextStage(StageRunStatus.notStarted), isFalse);
      expect(stageUnlocksNextStage(StageRunStatus.availableToStart), isFalse);
    });
  });

  test('легенда показывает все статусы без повторов', () {
    expect(
      kStageRunStatusLegendOrder.toSet().length,
      StageRunStatus.values.length,
    );
  });
}
