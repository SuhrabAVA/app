import 'package:flutter/material.dart';

import 'task_buttons_state.dart' show UserRunState;

/// Состояние этапа производства так, как его видит цех.
///
/// Это НЕ статус строки задачи: у этапа бывает несколько исполнителей, и их
/// состояния расходятся — один работает, второй на паузе, третий уже отметил
/// «Завершить». Что показать в такой ситуации, решает [resolveStageRunStatus].
enum StageRunStatus {
  /// Никто не начинал, и предыдущий этап тоже не начат.
  notStarted,

  /// Предыдущий этап уже начат — за этот можно браться.
  availableToStart,

  /// Кто-то работает прямо сейчас.
  inProgress,

  /// Работа приостановлена.
  paused,

  /// Зафиксирована проблема.
  problem,

  /// Пересмена: смена остановлена явно либо все отметились «Завершить»,
  /// а задание не закрыто.
  shiftChange,

  /// Нажата итоговая кнопка «Завершить задание».
  completed,
}

/// Цвет точки и подписи этапа.
Color stageRunStatusColor(StageRunStatus status) => switch (status) {
      StageRunStatus.inProgress => const Color(0xFF2563EB), // синий
      StageRunStatus.paused => const Color(0xFFEAB308), // жёлтый
      StageRunStatus.problem => const Color(0xFFDC2626), // красный
      StageRunStatus.shiftChange => const Color(0xFFF97316), // оранжевый
      StageRunStatus.notStarted => const Color(0xFF9CA3AF), // серый
      StageRunStatus.completed => const Color(0xFF22C55E), // зелёный
      StageRunStatus.availableToStart => const Color(0xFF86EFAC), // светло-зелёный
    };

/// Цвет ИМЕНИ участника этапа — по тому, чем он занят прямо сейчас.
///
/// Палитра та же, что у этапа, и это важно: два набора цветов на одном экране
/// сотрудник читал бы как два разных языка. Соответствие один в один —
/// работает = «В работе», пауза = «Пауза», проблема = «Проблема»,
/// завершил участие = «Завершён», не в работе = «Не начат».
Color participantRunStateColor(UserRunState state) => switch (state) {
      UserRunState.active => stageRunStatusColor(StageRunStatus.inProgress),
      UserRunState.paused => stageRunStatusColor(StageRunStatus.paused),
      UserRunState.problem => stageRunStatusColor(StageRunStatus.problem),
      UserRunState.finished => stageRunStatusColor(StageRunStatus.completed),
      UserRunState.idle => stageRunStatusColor(StageRunStatus.notStarted),
    };

/// Подпись состояния участника — для подсказки на наведении.
String participantRunStateLabel(UserRunState state) => switch (state) {
      UserRunState.active => 'Работает',
      UserRunState.paused => 'На паузе',
      UserRunState.problem => 'Проблема',
      UserRunState.finished => 'Завершил участие',
      UserRunState.idle => 'Не в работе',
    };

/// Подпись статуса — она же подпись в легенде.
String stageRunStatusLabel(StageRunStatus status) => switch (status) {
      StageRunStatus.inProgress => 'В работе',
      StageRunStatus.paused => 'Пауза',
      StageRunStatus.problem => 'Проблема',
      StageRunStatus.shiftChange => 'Пересмена',
      StageRunStatus.notStarted => 'Не начат',
      StageRunStatus.completed => 'Завершён',
      StageRunStatus.availableToStart => 'Доступен',
    };

/// Порядок статусов в легенде — от начала работы к её концу.
const List<StageRunStatus> kStageRunStatusLegendOrder = <StageRunStatus>[
  StageRunStatus.notStarted,
  StageRunStatus.availableToStart,
  StageRunStatus.inProgress,
  StageRunStatus.paused,
  StageRunStatus.shiftChange,
  StageRunStatus.problem,
  StageRunStatus.completed,
];

/// Открывает ли этап в таком состоянии следующий за ним.
///
/// То же правило, что разблокирует кнопку «Начать» в рабочем пространстве
/// (`_stageUnlocksNext` в stage_sequence_utils): следующему этапу достаточно,
/// чтобы предыдущий БЫЛ НАЧАТ. Он может стоять на паузе, на пересмене или с
/// проблемой — работа уже пошла, и держать следующий этап незачем.
bool stageUnlocksNextStage(StageRunStatus status) => switch (status) {
      StageRunStatus.notStarted => false,
      StageRunStatus.availableToStart => false,
      StageRunStatus.inProgress => true,
      StageRunStatus.paused => true,
      StageRunStatus.problem => true,
      StageRunStatus.shiftChange => true,
      StageRunStatus.completed => true,
    };

/// Один статус этапа из состояний всех его исполнителей.
///
/// Порядок проверок — это и есть правило разрешения конфликта, и он важен:
///
/// 1. [finalized] — «Завершён» ставится ТОЛЬКО по итоговой кнопке «Завершить
///    задание». Личное «Завершить участие» этап не закрывает: сотрудник вправе
///    вернуться и добрать количество.
/// 2. [anyProblem] — проблема перекрывает всё: пока её не сняли, этап красный,
///    даже если остальные спокойно работают. Иначе беда одного тонула бы в
///    активности других.
/// 3. [anyActive] — хотя бы один работает, значит этап идёт. Паузы и
///    завершения остальных на это не влияют.
/// 4. Пересмена: либо смену остановили явно ([shiftPaused]), либо все
///    исполнители отметились «Завершить», а задание не закрыто
///    ([allPerformersFinished]) — работа стоит, но этап не закончен.
/// 5. [anyPaused] — все, кто есть, на паузе.
/// 6. Этап начат, но никого нет и ни один флаг выше не подошёл — это тоже
///    остановка, показываем паузой, а не «не начат»: работа уже была.
/// 7. Нетронутый этап: светло-зелёный, если очередь до него дошла, иначе серый.
StageRunStatus resolveStageRunStatus({
  required bool finalized,
  required bool anyProblem,
  required bool anyActive,
  required bool shiftPaused,
  required bool hasPerformers,
  required bool allPerformersFinished,
  required bool anyPaused,
  required bool started,
  required bool availableToStart,
}) {
  if (finalized) return StageRunStatus.completed;
  if (anyProblem) return StageRunStatus.problem;
  if (anyActive) return StageRunStatus.inProgress;
  if (shiftPaused) return StageRunStatus.shiftChange;
  if (hasPerformers && allPerformersFinished) return StageRunStatus.shiftChange;
  if (anyPaused) return StageRunStatus.paused;
  if (started) return StageRunStatus.paused;
  return availableToStart
      ? StageRunStatus.availableToStart
      : StageRunStatus.notStarted;
}
