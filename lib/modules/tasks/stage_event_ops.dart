/// Операции этапа для RPC `task_apply_stage_events`.
///
/// Зачем файл существует: раньше одно действие цеха («начать этап»,
/// «пересмена») складывалось из четырёх-пяти независимых запросов, каждый со
/// своим `catch { debugPrint }`. На цеховой сети с 25-секундными таймаутами
/// часть из них молча терялась, и действие оставалось наполовину выполненным:
/// пересмена без записи `shift_pause`, старт без назначения исполнителя.
///
/// Теперь порядок операций собирается здесь — чистой функцией, без БД и
/// `BuildContext`, — и уходит на сервер одним вызовом. Сервер применяет список
/// целиком или не применяет вовсе.
library;

/// Тип интервала времени в payload `time_event`.
///
/// Значения совпадают с `taskTimeTypeToString` из [task_model.dart]: их читает
/// и клиент, и SQL, разойтись им нельзя.
class StageIntervalType {
  static const String production = 'production';
  static const String pause = 'pause';
  static const String problem = 'problem';
  static const String setup = 'setup';
  static const String shiftChange = 'shift_change';
}

/// Конструкторы отдельных операций.
///
/// Имена ключей — контракт с `public.task_apply_ops`; менять их можно только
/// вместе с миграцией.
class StageEventOps {
  const StageEventOps._();

  static Map<String, dynamic> addAssignee(String userId) => {
        'op': 'add_assignee',
        'userId': userId,
      };

  static Map<String, dynamic> removeAssignee(String userId) => {
        'op': 'remove_assignee',
        'userId': userId,
      };

  /// Сотрудник становится ЕДИНСТВЕННЫМ исполнителем этапа.
  ///
  /// Нужно пересмене: в совместном режиме заданием управляет только
  /// `assignees.first` (см. `isRowAssignee`), поэтому пришедшая смена обязана
  /// встать первой. Простое добавление в конец списка оставило бы её без
  /// единой доступной кнопки.
  ///
  /// Список считает сервер, а не клиент из своего снимка задачи: намерение
  /// здесь — «этап теперь мой», а не «запиши вот этот массив».
  static Map<String, dynamic> claimStage(String userId) => {
        'op': 'claim_stage',
        'userId': userId,
      };

  static Map<String, dynamic> comment({
    required String type,
    required String text,
    required String userId,
  }) =>
      {
        'op': 'comment',
        'type': type,
        'text': text,
        'userId': userId,
      };

  static Map<String, dynamic> closeInterval({
    required String subject,
    String? note,
  }) =>
      {
        'op': 'close_interval',
        'subject': subject,
        if (note != null) 'note': note,
      };

  static Map<String, dynamic> openInterval({
    required String subject,
    required String type,
    required String initiatedBy,
    required String workplaceId,
    required List<String> participants,
    String? executionMode,
    String? helperId,
    String? note,
  }) =>
      {
        'op': 'open_interval',
        'subject': subject,
        'type': type,
        'initiatedBy': initiatedBy,
        'workplaceId': workplaceId,
        'participants': participants,
        if (executionMode != null) 'executionMode': executionMode,
        if (helperId != null) 'helperId': helperId,
        if (note != null) 'note': note,
      };
}

/// Полный список операций для одного бизнес-действия.
///
/// Порядок внутри списка повторяет прежнюю цепочку запросов один в один —
/// иначе поменялось бы поведение, а не только надёжность.
class StageEventPlans {
  const StageEventPlans._();

  /// Сотрудник входит в работу на этапе.
  ///
  /// Назначение идёт ПЕРВЫМ и в одной транзакции с остальным. Раньше оно
  /// уходило отдельным запросом и терялось: комментарии и интервал
  /// записывались, а в `assignees` сотрудника не было — экран переставал
  /// показывать ему кнопки вообще.
  /// [setupDoneOps] встают между записью режима и отметкой старта — там же,
  /// где раньше вызывался _finishSetup. [helperIds] получают собственные
  /// интервалы: в совместном режиме этап запускает основной исполнитель, а
  /// время идёт всей бригаде.
  static List<Map<String, dynamic>> stageStart({
    required String userId,
    required String workplaceId,
    required List<String> participants,
    required bool alreadyAssigned,
    required bool isResume,
    String? stageExecutionModeCode,
    String? personalExecutionModeCode,
    String? intervalExecutionModeCode,
    List<Map<String, dynamic>> setupDoneOps = const <Map<String, dynamic>>[],
    List<String> helperIds = const <String>[],
  }) {
    return <Map<String, dynamic>>[
      if (!alreadyAssigned) StageEventOps.addAssignee(userId),
      if (stageExecutionModeCode != null)
        StageEventOps.comment(
          type: 'exec_mode_stage',
          text: stageExecutionModeCode,
          userId: userId,
        ),
      if (personalExecutionModeCode != null)
        StageEventOps.comment(
          type: 'exec_mode',
          text: personalExecutionModeCode,
          userId: userId,
        ),
      ...setupDoneOps,
      StageEventOps.comment(
        type: isResume ? 'resume' : 'start',
        text: isResume ? 'Возобновил(а) этап' : 'Начал(а) этап',
        userId: userId,
      ),
      StageEventOps.openInterval(
        subject: userId,
        type: StageIntervalType.production,
        initiatedBy: userId,
        workplaceId: workplaceId,
        participants: participants,
        executionMode: intervalExecutionModeCode,
      ),
      for (final helperId in helperIds)
        StageEventOps.openInterval(
          subject: helperId,
          type: StageIntervalType.production,
          initiatedBy: userId,
          workplaceId: workplaceId,
          participants: participants,
          executionMode: intervalExecutionModeCode,
          helperId: helperId,
        ),
    ];
  }

  /// Завершение наладки: отметка и закрытие интервалов наладки бригады.
  static List<Map<String, dynamic>> setupDone({
    required String userId,
    required String setupDoneText,
    required List<String> helperIds,
  }) {
    return <Map<String, dynamic>>[
      StageEventOps.comment(
        type: 'setup_done',
        text: setupDoneText,
        userId: userId,
      ),
      StageEventOps.closeInterval(subject: userId, note: 'setup_done'),
      for (final helperId in helperIds)
        StageEventOps.closeInterval(subject: helperId, note: 'setup_done'),
    ];
  }

  /// Этап останавливается на пересмену.
  ///
  /// [helpersToRelease] — помощники, которых пересмена снимает с этапа: их
  /// интервал закрывается и назначение снимается. Своего интервала пересмены
  /// они НЕ получают.
  ///
  /// Раньше получали — и пересмена на этапе с помощниками вообще не проходила:
  /// база не даёт снять исполнителя, у которого открыт интервал
  /// (`tasks_guard_active_assignees`), а новый интервал пересмены открывался
  /// сразу после снятия, в том же запросе. Весь набор откатывался с ошибкой
  /// «у него не закрыт интервал», и сделать пересмену удавалось только после
  /// ручного удаления всех помощников (15.09, «Ручка-склейка крученая»).
  /// Потери данных в этом нет: интервал пересмены — не рабочее время, в
  /// аналитике он не учитывается (`_mapType` → null).
  static List<Map<String, dynamic>> shiftPause({
    required String userId,
    required String workplaceId,
    required List<String> participants,
    required String resumeState,
    required List<String> helpersToRelease,
    String? executionModeCode,
    String? quantityCommentType,
    String? quantityCommentText,
  }) {
    return <Map<String, dynamic>>[
      if (quantityCommentType != null && quantityCommentText != null)
        StageEventOps.comment(
          type: quantityCommentType,
          text: quantityCommentText,
          userId: userId,
        ),
      for (final helperId in helpersToRelease)
        StageEventOps.closeInterval(subject: helperId, note: 'shift_change'),
      for (final helperId in helpersToRelease)
        StageEventOps.removeAssignee(helperId),
      StageEventOps.openInterval(
        subject: userId,
        type: StageIntervalType.shiftChange,
        initiatedBy: userId,
        workplaceId: workplaceId,
        participants: participants,
        executionMode: executionModeCode,
      ),
      // Эти два комментария и терялись: они шли последними в цепочке
      // независимых запросов. Теперь они в той же транзакции, что и интервал.
      StageEventOps.comment(
        type: 'shift_pause_state',
        text: resumeState,
        userId: userId,
      ),
      StageEventOps.comment(
        type: 'shift_pause',
        text: 'Пересмена: этап приостановлен',
        userId: userId,
      ),
    ];
  }

  /// Работа продолжается после пересмены.
  ///
  /// Пришедшая смена забирает этап себе — иначе она не сможет им управлять:
  /// в совместном режиме кнопки доступны только `assignees.first`. Отработанное
  /// время предыдущей смены при этом никуда не девается: аналитика считает по
  /// интервалам `time_event` (там свой `subjectUserId`), а не по составу
  /// исполнителей.
  /// [closeIntervalsFor] — у кого на ЭТОЙ задаче остался незакрытый интервал
  /// прошлой смены. Закрываем его здесь же, одной транзакцией с захватом
  /// этапа, а не отдельным запросом перед ней.
  ///
  /// Причин две. Отдельный запрос теряется на цеховой сети, и пересмена
  /// остаётся недооформленной. И вторая: база больше не позволяет снять с
  /// этапа человека с открытым интервалом (триггер
  /// `tasks_guard_active_assignees`), а `claim_stage` делает пришедшую смену
  /// единственным исполнителем — то есть снимает предыдущую. Не закрыв её
  /// интервал в том же вызове, возобновление упёрлось бы в защиту.
  ///
  /// Повтор безопасен: `close_interval` на уже закрытом интервале — пустая
  /// операция.
  static List<Map<String, dynamic>> shiftResume({
    required String userId,
    required String workplaceId,
    required List<String> participants,
    required String intervalType,
    required String resumeText,
    required bool needsSetupStart,
    List<String> closeIntervalsFor = const <String>[],
    String? executionModeCode,
  }) {
    return <Map<String, dynamic>>[
      for (final subject in closeIntervalsFor)
        if (subject.trim().isNotEmpty && subject.trim() != userId.trim())
          StageEventOps.closeInterval(subject: subject, note: 'shift_resume'),
      StageEventOps.claimStage(userId),
      if (needsSetupStart)
        StageEventOps.comment(
          type: 'setup_start',
          text: 'Начал(а) настройку станка',
          userId: userId,
        ),
      StageEventOps.openInterval(
        subject: userId,
        type: intervalType,
        initiatedBy: userId,
        workplaceId: workplaceId,
        participants: participants,
        executionMode: executionModeCode,
        note: 'shift_resume_$intervalType',
      ),
      StageEventOps.comment(
        type: 'shift_resume',
        text: resumeText,
        userId: userId,
      ),
    ];
  }

  /// Сотрудник в отдельном режиме завершает СВОЁ участие: личное количество,
  /// отметка «завершил» и закрытие его интервала.
  ///
  /// Раньше это были три отдельных вызова. На цеховой сети первый уходил в
  /// очередь повторов, экран не менялся, сотрудник жал «Завершить» ещё раз — и
  /// количество записывалось дважды (23 повтора на 14.09, на Упаковке
  /// 43 108 лишних единиц). Одним вызовом запись либо есть целиком, либо её
  /// нет; повтор после завершения сервер пропускает сам
  /// (`task_finish_record_is_repeat`).
  static List<Map<String, dynamic>> participantFinish({
    required String userId,
    required String quantityText,
  }) {
    return <Map<String, dynamic>>[
      StageEventOps.comment(
        type: 'quantity_done',
        text: quantityText,
        userId: userId,
      ),
      StageEventOps.comment(
        type: 'user_done',
        text: 'done',
        userId: userId,
      ),
      StageEventOps.closeInterval(subject: userId, note: 'user_done'),
    ];
  }

  /// Помощник снимается с этапа основным исполнителем.
  ///
  /// Количество здесь не спрашиваем — его доля считается по отработанному
  /// времени при завершении этапа, поэтому достаточно закрытого интервала.
  static List<Map<String, dynamic>> removeHelper({
    required String helperId,
    required String actorId,
    required String helperName,
  }) {
    return <Map<String, dynamic>>[
      StageEventOps.closeInterval(subject: helperId, note: 'helper_removed'),
      StageEventOps.removeAssignee(helperId),
      StageEventOps.comment(
        type: 'helper_removed',
        text: 'Помощник удалён: $helperName',
        userId: actorId,
      ),
    ];
  }

  /// Помощник добавлен основным исполнителем.
  ///
  /// Три записи режима нужны в разных точках вызова и потому передаются
  /// отдельно: [stageModeCode] — режим самого этапа, [actorModeCode] — режим
  /// основного исполнителя, [helperModeCode] — режим помощника. Пусто —
  /// значит запись уже есть и повторять её не надо.
  ///
  /// [openIntervalType] задан, только если этап уже идёт: помощнику нужен
  /// собственный интервал с этого момента, иначе его время потеряется.
  static List<Map<String, dynamic>> addHelper({
    required String helperId,
    required String actorId,
    required String workplaceId,
    required List<String> participants,
    String? stageModeCode,
    String? actorModeCode,
    String? helperModeCode,
    String? openIntervalType,
    String? intervalExecutionModeCode,
  }) {
    return <Map<String, dynamic>>[
      StageEventOps.addAssignee(helperId),
      if (stageModeCode != null)
        StageEventOps.comment(
          type: 'exec_mode_stage',
          text: stageModeCode,
          userId: actorId,
        ),
      if (actorModeCode != null)
        StageEventOps.comment(
          type: 'exec_mode',
          text: actorModeCode,
          userId: actorId,
        ),
      if (helperModeCode != null)
        StageEventOps.comment(
          type: 'exec_mode',
          text: helperModeCode,
          userId: helperId,
        ),
      StageEventOps.comment(
        type: 'joined',
        text: 'Присоединился(лась) к этапу',
        userId: helperId,
      ),
      if (openIntervalType != null)
        StageEventOps.openInterval(
          subject: helperId,
          type: openIntervalType,
          initiatedBy: actorId,
          workplaceId: workplaceId,
          participants: participants,
          executionMode: intervalExecutionModeCode,
          helperId: helperId,
        ),
    ];
  }
}
