import 'package:flutter/material.dart';

import '../../../utils/kostanay_time.dart';
import '../../personnel/workplace_model.dart';
import '../../tasks/task_comment_presentation.dart';
import '../calculators/timeline_calculator.dart';
import '../models/analytics_day_comment.dart';
import '../models/analytics_event.dart';
import 'quantity_edit_dialog.dart';
import '../utils/analytics_colors.dart';
import '../utils/format_utils.dart';

/// «Заказы и работы выбранного дня», сгруппированные по заказам.
///
/// Заголовок группы — имя заказчика (не id/номер заказа). Записи без заказа
/// (простой и т.п.) собираются в отдельную группу «Без заказа» в конце.
/// Группы — аккордеоны: по умолчанию свёрнуты, клик по заголовку разворачивает
/// записи заказа, повторный — сворачивает. Справа у заголовка — кнопка со
/// всеми комментариями заказа. Данные/запросы не меняются: это только
/// представление, сортировка внутри группы — по времени.
class DayEventsTable extends StatefulWidget {
  const DayEventsTable({
    super.key,
    required this.events,
    required this.timeline,
    required this.workplaceById,
    this.comments = const [],
    this.employeeNameOf,
    this.now,
    this.canEditQuantity = false,
    this.onQuantityEdited,
  });

  final List<AnalyticsEvent> events;
  final TimelineLayout timeline;
  final Map<String, WorkplaceModel> workplaceById;

  /// Дополнительный слой отображения: комментарии/события этапов за день.
  /// На расчётные строки (и цифры зарплаты/КПД) не влияет.
  final List<AnalyticsDayComment> comments;
  final String Function(String employeeId)? employeeNameOf;
  final DateTime? now;

  /// Может ли текущий пользователь исправлять количество (техлид).
  /// Ячейка «Количество» становится нажимаемой только тогда.
  final bool canEditQuantity;

  /// Вызывается после успешной правки: экран перезагружает месяц.
  final VoidCallback? onQuantityEdited;

  @override
  State<DayEventsTable> createState() => _DayEventsTableState();
}

class _DayEventsTableState extends State<DayEventsTable> {
  static const String _noOrderKey = '__no_order__';

  /// Ключи развёрнутых групп. Пусто = все свёрнуты (поведение по умолчанию).
  final Set<String> _expanded = <String>{};

  @override
  Widget build(BuildContext context) {
    final reference = widget.now ?? nowInKostanay();
    final groups = _buildGroups(reference);

    if (groups.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(
          child: Text(
            'На выбранный день нет событий',
            style: TextStyle(color: AnalyticsColors.muted),
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final g in groups) _buildGroup(g),
      ],
    );
  }

  Widget _buildGroup(_OrderGroup g) {
    final expanded = _expanded.contains(g.key);
    final hasComments = g.comments.isNotEmpty;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: AnalyticsColors.card2.withOpacity(0.55),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => setState(() {
              if (expanded) {
                _expanded.remove(g.key);
              } else {
                _expanded.add(g.key);
              }
            }),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              child: Row(
                children: [
                  Icon(
                    expanded ? Icons.expand_less : Icons.expand_more,
                    color: AnalyticsColors.muted,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          g.title,
                          style: TextStyle(
                            color: g.isNoOrder
                                ? AnalyticsColors.muted
                                : AnalyticsColors.text,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          g.summaryLabel(),
                          style: const TextStyle(
                            color: AnalyticsColors.muted,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (hasComments)
                    IconButton(
                      tooltip: 'Комментарии заказа',
                      icon: const Icon(Icons.chat_bubble_outline, size: 18),
                      color: AnalyticsColors.muted,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 36,
                        minHeight: 36,
                      ),
                      onPressed: () => _showComments(g),
                    ),
                ],
              ),
            ),
          ),
          if (expanded) ...[
            Divider(
              height: 1,
              color: AnalyticsColors.line.withOpacity(0.35),
            ),
            _buildRecordsTable(g),
            if (g.comments.isNotEmpty) _buildCommentsSection(g),
          ],
        ],
      ),
    );
  }

  Widget _buildRecordsTable(_OrderGroup g) {
    return Table(
      columnWidths: const {
        0: FlexColumnWidth(1.6),
        1: FlexColumnWidth(1.1),
        2: FlexColumnWidth(1.0),
        3: FlexColumnWidth(1.1),
        4: FlexColumnWidth(1.8),
      },
      defaultVerticalAlignment: TableCellVerticalAlignment.middle,
      border: TableBorder(
        horizontalInside: BorderSide(
          color: AnalyticsColors.line.withOpacity(0.25),
        ),
      ),
      children: [
        _recordsHeader(),
        for (final row in g.rows) _recordRow(row),
      ],
    );
  }

  TableRow _recordsHeader() {
    return TableRow(
      children: [
        _hcell('Рабочее место'),
        _hcell('Время'),
        _hcell('Длительность'),
        _hcell('Количество'),
        _hcell('Описание'),
      ],
    );
  }

  TableRow _recordRow(_DayRow row) {
    return TableRow(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                margin: const EdgeInsets.only(bottom: 4),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: row.badgeColor.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  row.badgeLabel,
                  style: TextStyle(
                    color: row.badgeColor,
                    fontSize: 10,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              Text(
                row.wpName,
                style: const TextStyle(
                  color: AnalyticsColors.text,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
        _cell(row.timeLabel),
        _cell(row.durationLabel),
        _quantityCell(row),
        _cell(row.description, maxLines: 3, isMuted: true),
      ],
    );
  }

  /// Секция «События» внутри развёрнутой группы: комментарии, проблемы,
  /// паузы, старт/завершение этапов — только отображение, без расчётов.
  Widget _buildCommentsSection(_OrderGroup g) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'СОБЫТИЯ',
            style: TextStyle(
              color: AnalyticsColors.tableHeaderText,
              fontSize: 10,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.04,
            ),
          ),
          const SizedBox(height: 4),
          for (final c in g.comments)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    taskCommentIcon(c.type),
                    size: 14,
                    color: taskCommentColor(c.type, c.text),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      _describeDayComment(c),
                      style: const TextStyle(
                        color: AnalyticsColors.muted,
                        fontSize: 11,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  String _describeDayComment(AnalyticsDayComment c) {
    final author = widget.employeeNameOf?.call(c.userId) ?? '';
    final wp = widget.workplaceById[c.workplaceId]?.name ?? '';
    final parts = <String>[
      _hhmm(c.timestamp),
      if (author.isNotEmpty) author,
      if (wp.isNotEmpty) wp,
    ];
    final description = describeTaskComment(
      c.type,
      c.text,
      resolveUserName: widget.employeeNameOf,
    );
    return '${parts.join(' · ')} — $description';
  }

  void _showComments(_OrderGroup g) {
    // Единый список: dayComments уже содержат паузы/проблемы/комментарии
    // (сырые note расчётных событий их дублировали — убраны).
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Комментарии — ${g.title}'),
        content: SizedBox(
          width: 420,
          child: g.comments.isEmpty
              ? const Text('Нет комментариев')
              : ListView(
                  shrinkWrap: true,
                  children: [
                    for (final c in g.comments)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(
                              taskCommentIcon(c.type),
                              size: 16,
                              color: taskCommentColor(c.type, c.text),
                            ),
                            const SizedBox(width: 6),
                            Expanded(child: Text(_describeDayComment(c))),
                          ],
                        ),
                      ),
                  ],
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Закрыть'),
          ),
        ],
      ),
    );
  }

  Widget _hcell(String s) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Text(
          s.toUpperCase(),
          style: const TextStyle(
            color: AnalyticsColors.tableHeaderText,
            fontSize: 10,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.04,
          ),
        ),
      );

  /// Ячейка количества: у техлида это кнопка правки, у остальных — текст.
  ///
  /// Нажимаемой становится только строка с исходными записями: у простоя и
  /// пауз править нечего.
  Widget _quantityCell(_DayRow row) {
    final event = row.event;
    final canEdit = widget.canEditQuantity &&
        event != null &&
        event.qtySources.any((s) => s.commentId.trim().isNotEmpty);
    if (!canEdit) return _cell(row.quantityLabel);

    return InkWell(
      onTap: () async {
        final saved = await showQuantityEditDialog(
          context: context,
          event: event,
          workplaceUnit: _unitFor(event.workplaceId),
        );
        if (saved) widget.onQuantityEdited?.call();
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                row.quantityLabel,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AnalyticsColors.text,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  decoration: TextDecoration.underline,
                ),
              ),
            ),
            const SizedBox(width: 4),
            const Icon(Icons.edit_outlined, size: 13, color: AnalyticsColors.muted),
          ],
        ),
      ),
    );
  }

  String _unitFor(String workplaceId) {
    final wp = widget.workplaceById[workplaceId];
    final unit = wp?.unit?.trim() ?? '';
    return unit.isNotEmpty ? unit : 'ед.';
  }

  Widget _cell(String value, {int maxLines = 2, bool isMuted = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Text(
        value,
        maxLines: maxLines,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: isMuted ? AnalyticsColors.muted : AnalyticsColors.text,
          fontSize: 12,
        ),
      ),
    );
  }

  /// Группирует записи дня по заказам. Заголовок — имя заказчика; записи без
  /// заказа (в т.ч. idle-простой) уходят в группу «Без заказа». Порядок групп:
  /// заказы по времени первого события, «Без заказа» — всегда последней.
  List<_OrderGroup> _buildGroups(DateTime reference) {
    final map = <String, _OrderGroup>{};

    _OrderGroup groupFor(String key, String title, bool isNoOrder) =>
        map.putIfAbsent(
          key,
          () => _OrderGroup(key: key, title: title, isNoOrder: isNoOrder),
        );

    for (final e in widget.events) {
      final start = e.startTime;
      final end = e.endTime ?? reference;
      final wp = widget.workplaceById[e.workplaceId];
      final unit =
          wp?.unit?.trim().isNotEmpty == true ? wp!.unit!.trim() : 'ед.';
      final wpName = wp?.name ?? e.workplaceId;
      final rawDuration = end.difference(start).inMinutes;
      final duration = rawDuration < 0 ? 0 : rawDuration;
      final timeStr =
          '${_hhmm(start)}–${_hhmm(end)}${e.endTime == null ? ' (активно)' : ''}';
      final qtyStr = e.type == AnalyticsEventType.work
          ? (e.qty > 0 ? '${AnalyticsFormat.decimal(e.qty)} $unit' : '—')
          : e.type == AnalyticsEventType.setup
              ? (e.setupQty > 0
                  ? 'приладка: ${AnalyticsFormat.decimal(e.setupQty)} $unit'
                  : '—')
              : '—';
      final description = (e.note ?? '').isNotEmpty ? e.note! : e.type.label;

      final orderId = e.orderId.trim();
      final customer = (e.customer ?? '').trim();
      final hasOrder = orderId.isNotEmpty;
      final key = hasOrder ? orderId : _noOrderKey;
      final title =
          hasOrder ? (customer.isNotEmpty ? customer : '—') : 'Без заказа';

      groupFor(key, title, !hasOrder).rows.add(_DayRow(
            startSort: start,
            wpName: wpName,
            timeLabel: timeStr,
            durationMinutes: duration,
            durationLabel: AnalyticsFormat.onlyMinutes(duration),
            quantityLabel: qtyStr,
            event: e,
            description: description,
            note: e.note,
            badgeColor: _colorFor(e.type),
            badgeLabel: e.type.label,
          ));
    }

    // idle-сегменты (простой) — в «Без заказа».
    for (final seg in widget.timeline.segments) {
      if (seg.type != AnalyticsEventType.idle) continue;
      final startMid = DateTime(
        widget.events.isNotEmpty
            ? widget.events.first.startTime.year
            : reference.year,
        widget.events.isNotEmpty
            ? widget.events.first.startTime.month
            : reference.month,
        widget.events.isNotEmpty
            ? widget.events.first.startTime.day
            : reference.day,
      );
      final start = startMid.add(Duration(minutes: seg.startMinutes));
      final end = startMid.add(Duration(minutes: seg.endMinutes));
      groupFor(_noOrderKey, 'Без заказа', true).rows.add(_DayRow(
            startSort: start,
            wpName: '—',
            timeLabel: '${_hhmm(start)}–${_hhmm(end)}',
            durationMinutes: seg.durationMinutes,
            durationLabel: AnalyticsFormat.onlyMinutes(seg.durationMinutes),
            quantityLabel: '—',
            description: 'Простой',
            note: null,
            badgeColor: AnalyticsColors.tlIdle,
            badgeLabel: 'Простой',
          ));
    }

    // События/комментарии этапов — в группы соответствующих заказов.
    for (final c in widget.comments) {
      final orderId = c.orderId.trim();
      final hasOrder = orderId.isNotEmpty;
      final key = hasOrder ? orderId : _noOrderKey;
      final customer = (c.customer ?? '').trim();
      final title =
          hasOrder ? (customer.isNotEmpty ? customer : '—') : 'Без заказа';
      groupFor(key, title, !hasOrder).comments.add(c);
    }

    // Сортировка внутри группы — по времени (как в плоском списке).
    for (final g in map.values) {
      g.rows.sort((a, b) => a.startSort.compareTo(b.startSort));
      g.comments.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    }

    final groups = map.values.toList();
    groups.sort((a, b) {
      if (a.isNoOrder != b.isNoOrder) return a.isNoOrder ? 1 : -1;
      return a.earliest.compareTo(b.earliest);
    });
    return groups;
  }

  Color _colorFor(AnalyticsEventType t) {
    switch (t) {
      case AnalyticsEventType.work:
        return AnalyticsColors.tlWork;
      case AnalyticsEventType.setup:
        return AnalyticsColors.tlSetup;
      case AnalyticsEventType.pause:
        return AnalyticsColors.tlPause;
      case AnalyticsEventType.problem:
        return AnalyticsColors.tlProblem;
      case AnalyticsEventType.idle:
        return AnalyticsColors.tlIdle;
    }
  }

  String _hhmm(DateTime dt) {
    // Время событий и дневных комментариев уже приведено к Костанайскому
    // (UTC+5) в TaskAnalyticsMapper / AnalyticsRepository. Читаем компоненты
    // напрямую — повторный toLocal() снова сдвинул бы на таймзону устройства.
    return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }
}

/// Русская форма слова «запись» по числу.
String _pluralRecords(int n) {
  final mod100 = n % 100;
  final mod10 = n % 10;
  final String word;
  if (mod100 >= 11 && mod100 <= 14) {
    word = 'записей';
  } else if (mod10 == 1) {
    word = 'запись';
  } else if (mod10 >= 2 && mod10 <= 4) {
    word = 'записи';
  } else {
    word = 'записей';
  }
  return '$n $word';
}

class _OrderGroup {
  _OrderGroup({
    required this.key,
    required this.title,
    required this.isNoOrder,
  });

  final String key;
  final String title;
  final bool isNoOrder;
  final List<_DayRow> rows = [];

  /// Отображаемые события/комментарии этапов этого заказа за день.
  final List<AnalyticsDayComment> comments = [];

  DateTime get earliest => rows.isEmpty
      ? DateTime.fromMillisecondsSinceEpoch(0)
      : rows.first.startSort;

  int get totalMinutes => rows.fold(0, (sum, r) => sum + r.durationMinutes);

  /// Краткая сводка свёрнутой группы: число записей + суммарная длительность.
  String summaryLabel() =>
      '${_pluralRecords(rows.length)} · ${AnalyticsFormat.hoursMinutes(totalMinutes)}';
}

class _DayRow {
  final DateTime startSort;
  final String wpName;
  final String timeLabel;
  final int durationMinutes;
  final String durationLabel;
  final String quantityLabel;

  /// Событие строки — нужно, чтобы открыть правку количества по его
  /// исходным записям. null у строк-заглушек (например, простоя).
  final AnalyticsEvent? event;
  final String description;
  final String? note;
  final Color badgeColor;
  final String badgeLabel;

  const _DayRow({
    required this.startSort,
    required this.wpName,
    required this.timeLabel,
    required this.durationMinutes,
    required this.durationLabel,
    required this.quantityLabel,
    this.event,
    required this.description,
    required this.note,
    required this.badgeColor,
    required this.badgeLabel,
  });
}
