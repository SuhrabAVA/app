/// Кто работал на этапе заказа и сколько каждый сделал.
///
/// Записи количества в `tasks.comments` служат двум целям (см.
/// `stage_quantity_records`): одни задают ТИРАЖ ЭТАПА, другие — ПЕРСОНАЛЬНУЮ
/// долю участника. Складывать их в одну сумму нельзя, поэтому здесь два
/// разных счёта:
///
///   * личное каждого — `quantity_share` (доля, в том числе рассчитанная
///     сервером) и `quantity_done` (одиночный режим, человек сам ввёл своё);
///   * тираж этапа — те же правила, что и для факта по заказу
///     (`countsTowardOrderQuantity`), чтобы карточка этапа и `orders.actual_qty`
///     не разошлись в числах.
///
/// Четыре правила, без которых карточка врала
/// ------------------------------------------
/// 1. **Круг этапа.** Возобновление завершённого этапа (`stage_reopened`)
///    начинает новый круг. Раньше суммировались записи ВСЕХ кругов, и
///    перезапущенный этап показывал удвоенный тираж — при том, что состояние
///    участников (`userRunState`) считалось только по текущему кругу, и числа
///    расходились с подсветкой. Теперь обе стороны смотрят на один круг.
///
/// 2. **Кто вообще участник.** Список строился по `assignees` и авторам узкого
///    набора комментариев. Человек, сделавший наладку и ушедший на пересмену,
///    не попадал в него вовсе — его имени на карточке просто не было, хотя
///    время этапа он потратил. Теперь участником считается и тот, кто начинал
///    наладку, вставал на пересмену, фиксировал проблему или вводил тираж.
///
/// 3. **Тираж отрезка — не «ничьё».** `quantity_stage_total` пишется на
///    пересмене и при завершении: это выработка БРИГАДЫ за отрезок, а не личный
///    вклад того, кто ввёл число. Персональные доли считает сервер
///    (`recompute_task_quantity_shares`), но на четырёх завершённых этапах из
///    пяти этих записей нет. В результате у людей стоял прочерк даже там, где
///    количество ввели, а сумма по именам расходилась с «Итого» в разы. Пока
///    серверных долей нет, отрезок делится здесь по фактически отработанному
///    времени — по той же формуле, что в `task_quantity_share_preview`, — и
///    помечается как предварительный.
///
/// 4. **Отрезок без работы — тем более не «ничьё».** Количество вводят и после
///    остановки: сотрудник ушёл на срочный заказ, станок встал на пересмену, а
///    выработку смены записали часом позже. Производственных интервалов в
///    таком отрезке ноль, и раньше он выбрасывался целиком — в «Итого» число
///    было, а в личной выработке и в сдельной его не видел никто. Теперь
///    отрезок засчитывается автору записи.
///
/// Участник без количества из списка всё равно не выпадает: он работал на
/// этапе, и молча его спрятать хуже, чем показать прочерк.
library;

import 'stage_quantity_records.dart';
import 'task_buttons_state.dart' show UserRunState;
import 'task_completion_rules.dart' show stageRoundStartMillis;
import 'task_model.dart';
import 'task_run_state.dart';

/// Типы записей, которые считаются ЛИЧНЫМ вкладом их автора.
const Set<String> kPersonalQuantityCommentTypes = <String>{
  'quantity_share',
  'quantity_done',
};

/// Меньше этого времени в отрезке — не участие, а рассинхрон меток.
///
/// Сервер закрывает интервал меткой с микросекундами, а границу отрезка пишет в
/// миллисекундах, и хвост интервала сдавшего смену попадал в СЛЕДУЮЩИЙ отрезок.
/// На станке без деления по времени это давало ему полный тираж чужой смены
/// (Лостовец, Флексопечать: 550 м при `seconds: 0.000154`). Порог тот же, что
/// `c_min_seconds` в `task_quantity_share_preview` (20260914).
const int kMinSegmentParticipationMillis = 1000;

/// Комментарии, по которым видно, что человек работал на этапе.
///
/// Список намеренно широкий: любая отметка, которую невозможно оставить, не
/// находясь на этапе, делает человека участником. Узкий список прятал с
/// карточки наладчиков и тех, кто передал смену.
const Set<String> _participationCommentTypes = <String>{
  'start',
  'resume',
  'joined',
  'user_done',
  'setup_start',
  'setup_resume',
  'setup_done',
  'shift_pause',
  'shift_resume',
  'problem',
  kStageTotalCommentType,
  'quantity_team_total',
};

/// Порядок, в котором состояния перебивают друг друга при подсветке имени.
///
/// ВНИМАНИЕ: он НЕ совпадает с порядком у этапа
/// (`resolveStageRunStatus`), где проблема стоит ВЫШЕ работы. И это
/// осознанно, а не рассогласование:
///
///   * цвет ЭТАПА отвечает на вопрос «что с заданием» — зафиксированная
///     проблема важнее того, что кто-то продолжает работать;
///   * цвет ИМЕНИ отвечает на вопрос «что делает ЭТОТ человек сейчас», и если
///     он работает, то он работает — независимо от того, что на этапе висит
///     чья-то проблема.
///
/// Меньший индекс перебивает больший.
const List<UserRunState> _statePriority = <UserRunState>[
  UserRunState.active,
  UserRunState.problem,
  UserRunState.paused,
  UserRunState.finished,
  UserRunState.idle,
];

/// Что участник делает на этапе СЕЙЧАС.
///
/// У этапа бывает несколько задач (группа альтернативных рабочих мест), и
/// человек может числиться в нескольких — состояния сводим по
/// [_statePriority].
UserRunState participantRunState(Iterable<TaskModel> tasks, String userId) {
  var best = _statePriority.length - 1;
  for (final task in tasks) {
    final state = userRunState(task, userId);
    final index = _statePriority.indexOf(state);
    if (index >= 0 && index < best) best = index;
  }
  return _statePriority[best];
}

/// Сколько сделал один участник этапа и что он делает сейчас.
class StageParticipantOutput {
  const StageParticipantOutput({
    required this.userId,
    required this.state,
    this.qty,
    this.provisional = false,
  });

  final String userId;

  /// Чем занят прямо сейчас — этим подсвечивается имя.
  final UserRunState state;

  /// Личный вклад. `null` — участвовал, но количества по нему нет вовсе.
  final double? qty;

  /// Доля посчитана здесь из тиража отрезка, а не взята из записи сервера.
  /// Показывается со знаком «≈»: к зарплате идёт серверный расчёт, и выдавать
  /// прикидку за окончательное число нельзя.
  final bool provisional;

  bool get hasQty => qty != null;
}

/// Итог по этапу: участники и общий тираж.
class StageOutput {
  const StageOutput({
    required this.participants,
    required this.totalQty,
    required this.hasTotal,
  });

  static const empty =
      StageOutput(participants: [], totalQty: 0, hasTotal: false);

  final List<StageParticipantOutput> participants;

  /// Тираж этапа за текущий круг.
  final double totalQty;

  /// Была ли хоть одна запись количества. Отличает «сделали 0» от «ещё не
  /// вводили»: в первом случае ноль осмыслен, во втором показывать его нельзя.
  final bool hasTotal;
}

/// Разбор этапа по его задачам.
///
/// [tasks] — все задачи этапа для одного заказа (у группы альтернативных
/// рабочих мест их несколько).
///
/// [splitByTime] — правило рабочего места (`workplaces.split_quantity_by_time`).
/// На станках, где тираж делает машина, а бригада её обслуживает, отрезок не
/// делится: каждому участнику засчитывается полное количество. Значение по
/// умолчанию совпадает с серверным (`coalesce(..., true)`).
StageOutput stageOutputForTasks(
  Iterable<TaskModel> tasks, {
  bool splitByTime = true,
}) {
  final order = <String>[];
  final personal = <String, double>{};
  final derived = <String, double>{};
  final seen = <String>{};
  var total = 0.0;
  var hasTotal = false;

  void remember(String userId) {
    final id = userId.trim();
    if (id.isEmpty || !seen.add(id)) return;
    order.add(id);
  }

  for (final task in tasks) {
    // Круг этапа: возобновлённый этап считается заново, прошлая жизнь в
    // текущие числа не входит.
    final roundStart = stageRoundStartMillis(task);

    // Назначенные идут первыми и в своём порядке: первый в `assignees` —
    // владелец этапа, и в списке он должен стоять сверху.
    for (final assignee in task.assignees) {
      remember(assignee);
    }

    final comments = <Map<String, dynamic>>[];
    for (final c in task.comments) {
      final ts = normalizeEpochToMillis(c.timestamp);
      if (ts < roundStart) continue;
      comments.add(<String, dynamic>{
        'type': c.type,
        'text': c.text,
        'userId': c.userId,
        'timestamp': ts,
      });
    }

    final helperIds = helperIdsFromComments(
      assignees: task.assignees,
      comments: comments,
    );

    // Сервер уже посчитал доли — тогда отрезки здесь делить нельзя, иначе
    // выработка удвоится.
    final hasServerShares = comments.any(
      (c) => stageCommentType(c) == 'quantity_share' && isGeneratedShare(c),
    );

    final segments = <_Segment>[];

    for (final comment in comments) {
      final type = stageCommentType(comment);
      final userId = stageCommentUserId(comment);

      if (_participationCommentTypes.contains(type) ||
          kPersonalQuantityCommentTypes.contains(type)) {
        // Удалённый из `assignees` помощник остаётся участником: он работал.
        remember(userId);
      }

      final qty = parseStageQuantityActual((comment['text'] ?? '').toString());

      if (kPersonalQuantityCommentTypes.contains(type) &&
          qty > 0 &&
          userId.isNotEmpty) {
        personal.update(userId, (value) => value + qty, ifAbsent: () => qty);
      }

      // Тираж отрезка. Личным вкладом автора он не является — это выработка
      // бригады за отрезок между пересменами.
      if (type == kStageTotalCommentType && qty > 0 && !hasServerShares) {
        segments.add(_Segment(
          endMillis: (comment['timestamp'] as int?) ?? 0,
          qty: qty,
          userId: userId,
        ));
      }

      if (countsTowardOrderQuantity(comment: comment, helperIds: helperIds)) {
        if (qty > 0) {
          total += qty;
          hasTotal = true;
        }
      }
    }

    if (segments.isNotEmpty) {
      _distributeSegments(
        task: task,
        segments: segments,
        roundStart: roundStart,
        splitByTime: splitByTime,
        into: derived,
        remember: remember,
      );
    }
  }

  final participants = <StageParticipantOutput>[];
  for (final userId in order) {
    final own = personal[userId];
    final share = derived[userId];
    double? qty;
    var provisional = false;
    if (own != null && share != null) {
      qty = own + _round(share, splitByTime);
      provisional = true;
    } else if (own != null) {
      qty = own;
    } else if (share != null) {
      qty = _round(share, splitByTime);
      provisional = true;
    }
    participants.add(StageParticipantOutput(
      userId: userId,
      state: participantRunState(tasks, userId),
      qty: qty,
      provisional: provisional,
    ));
  }

  return StageOutput(
    participants: participants,
    totalQty: total,
    hasTotal: hasTotal,
  );
}

/// Округление доли — одно на этап, как в `recompute_task_quantity_shares`:
/// неполная упаковка считается за целую, но округлять каждый отрезок значило
/// бы округлять по три раза за смену.
double _round(double value, bool splitByTime) =>
    splitByTime ? value.ceilToDouble() : value;

class _Segment {
  const _Segment({
    required this.endMillis,
    required this.qty,
    required this.userId,
  });
  final int endMillis;
  final double qty;

  /// Кто ввёл запись тиража — нужен, когда делить отрезок не на кого.
  final String userId;
}

/// Делит тиражи отрезков между теми, кто в этих отрезках работал.
///
/// Отрезок — промежуток между двумя записями тиража: пересмена закрывает
/// предыдущий и открывает следующий. Внутри отрезка вес участника это сумма
/// его ПРОИЗВОДСТВЕННЫХ интервалов, попавших в отрезок. Наладка в вес не
/// входит: она оплачивается отдельной строкой по цене рабочего места, и
/// засчитав её ещё и во время работы, наладчику заплатили бы дважды за один
/// час — то же правило действует на сервере.
void _distributeSegments({
  required TaskModel task,
  required List<_Segment> segments,
  required int roundStart,
  required bool splitByTime,
  required Map<String, double> into,
  required void Function(String userId) remember,
}) {
  final production = taskTimeEvents(task)
      .where((e) => e.type == TaskTimeType.production)
      .where((e) => e.startTime.millisecondsSinceEpoch >= roundStart)
      .toList(growable: false);
  if (production.isEmpty) return;

  final ordered = [...segments]
    ..sort((a, b) => a.endMillis.compareTo(b.endMillis));
  final nowMillis = DateTime.now().toUtc().millisecondsSinceEpoch;

  var from = roundStart;
  if (from == 0) {
    from = production
        .map((e) => e.startTime.millisecondsSinceEpoch)
        .reduce((a, b) => a < b ? a : b);
  }

  for (final segment in ordered) {
    final to = segment.endMillis;
    if (to <= from) continue;

    final seconds = <String, double>{};
    for (final event in production) {
      final userId = event.subjectUserId.trim();
      if (userId.isEmpty) continue;
      final start = event.startTime.millisecondsSinceEpoch;
      final end = event.endTime?.millisecondsSinceEpoch ?? nowMillis;
      final overlap = (end < to ? end : to) - (start > from ? start : from);
      if (overlap <= 0) continue;
      seconds.update(userId, (v) => v + overlap / 1000,
          ifAbsent: () => overlap / 1000);
    }
    seconds.removeWhere(
        (_, value) => value * 1000 < kMinSegmentParticipationMillis);

    if (seconds.isEmpty) {
      // Отрезок без производственных интервалов: станок стоял на пересмене или
      // «проблеме», а тираж ввели уже после остановки. Делить не на кого, но и
      // выбросить нельзя — вместе с отрезком пропадала чужая смена: на «Фри»
      // заказа Burger king так потерялись 17 000 шт из 30 503, и в сдельную
      // они не попали никому. Засчитываем автору записи: на пересмене
      // количество вводит сдающий смену, то есть за свою же работу.
      final author = segment.userId.trim();
      if (author.isNotEmpty) {
        remember(author);
        into.update(author, (v) => v + segment.qty,
            ifAbsent: () => segment.qty);
      }
      from = to;
      continue;
    }

    for (final userId in seconds.keys) {
      remember(userId);
    }

    if (!splitByTime) {
      // Тираж делает станок: каждому участнику отрезка засчитывается полное
      // количество, делить нечего.
      for (final userId in seconds.keys) {
        into.update(userId, (v) => v + segment.qty,
            ifAbsent: () => segment.qty);
      }
      from = to;
      continue;
    }

    final totalSeconds = seconds.values.fold<double>(0, (a, b) => a + b);
    for (final entry in seconds.entries) {
      // Мгновенное завершение или сбитые часы: делим поровну, а не падаем —
      // остановить карточку из-за битой метки времени дороже.
      final share = totalSeconds <= 0
          ? segment.qty / seconds.length
          : segment.qty * entry.value / totalSeconds;
      into.update(entry.key, (v) => v + share, ifAbsent: () => share);
    }
    from = to;
  }
}

/// Количество без хвоста «.0» у целых.
String formatStageQty(double? qty) {
  if (qty == null) return '—';
  final rounded = (qty * 100).round() / 100;
  if (rounded == rounded.roundToDouble()) return rounded.toStringAsFixed(0);
  var text = rounded.toStringAsFixed(2);
  text = text.replaceFirst(RegExp(r'0+$'), '');
  return text.replaceFirst(RegExp(r'\.$'), '');
}
