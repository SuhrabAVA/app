import 'package:flutter/material.dart';

import '../../personnel/workplace_model.dart';
import '../calculators/timeline_calculator.dart';
import '../models/analytics_event.dart';
import '../utils/analytics_colors.dart';
import '../utils/format_utils.dart';

/// Таблица "Заказы и работы выбранного дня" с 5 колонками:
/// Заказчик / рабочее место | Время | Длительность | Количество | Описание.
class DayEventsTable extends StatelessWidget {
  const DayEventsTable({
    super.key,
    required this.events,
    required this.timeline,
    required this.workplaceById,
    this.now,
  });

  final List<AnalyticsEvent> events;
  final TimelineLayout timeline;
  final Map<String, WorkplaceModel> workplaceById;
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final reference = now ?? DateTime.now();
    final rows = _buildRows(reference);

    if (rows.isEmpty) {
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

    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: Table(
        columnWidths: const {
          0: FlexColumnWidth(1.7),
          1: FlexColumnWidth(1.0),
          2: FlexColumnWidth(0.9),
          3: FlexColumnWidth(1.0),
          4: FlexColumnWidth(1.7),
        },
        defaultVerticalAlignment: TableCellVerticalAlignment.middle,
        border: TableBorder(
          horizontalInside: BorderSide(
            color: AnalyticsColors.line.withOpacity(0.35),
          ),
        ),
        children: [
          _header(),
          for (final row in rows) row,
        ],
      ),
    );
  }

  TableRow _header() {
    return TableRow(
      decoration: const BoxDecoration(color: Color(0xFF121A2E)),
      children: [
        _hcell('Заказчик / рабочее место'),
        _hcell('Время'),
        _hcell('Длительность'),
        _hcell('Количество'),
        _hcell('Описание'),
      ],
    );
  }

  Widget _hcell(String s) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        child: Text(
          s.toUpperCase(),
          style: const TextStyle(
            color: Color(0xFFCBD5E1),
            fontSize: 11,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.04,
          ),
        ),
      );

  List<TableRow> _buildRows(DateTime reference) {
    // Каждое событие — отдельная строка. Также добавляем idle-сегменты
    // как простой.
    final entries = <_DayRow>[];

    for (final e in events) {
      final start = e.startTime;
      final end = e.endTime ?? reference;
      final wp = workplaceById[e.workplaceId];
      final unit = wp?.unit?.trim().isNotEmpty == true ? wp!.unit!.trim() : 'ед.';

      final customer = (e.customer ?? '').isNotEmpty ? e.customer! : '—';
      final wpName = wp?.name ?? e.workplaceId;
      final timeStr =
          '${_hhmm(start)}–${_hhmm(end)}${e.endTime == null ? ' (активно)' : ''}';
      final duration = end.difference(start).inMinutes;
      final qtyStr = e.type == AnalyticsEventType.work
          ? (e.qty > 0 ? '${AnalyticsFormat.decimal(e.qty)} $unit' : '—')
          : e.type == AnalyticsEventType.setup
              ? (e.setupQty > 0
                  ? 'приладка: ${AnalyticsFormat.decimal(e.setupQty)} $unit'
                  : '—')
              : '—';
      final description = (e.note ?? '').isNotEmpty ? e.note! : e.type.label;

      entries.add(_DayRow(
        startSort: start,
        leftLabel: '$customer\n$wpName',
        timeLabel: timeStr,
        durationLabel: AnalyticsFormat.onlyMinutes(duration),
        quantityLabel: qtyStr,
        description: description,
        badgeColor: _colorFor(e.type),
        badgeLabel: e.type.label,
      ));
    }

    // Добавляем idle сегменты.
    for (final seg in timeline.segments) {
      if (seg.type != AnalyticsEventType.idle) continue;
      final startMid = DateTime(
        // используем тот же день для idle: они в координатах минут, поэтому
        // показываем по самому первому событию или по сегодняшнему дню.
        events.isNotEmpty ? events.first.startTime.year : reference.year,
        events.isNotEmpty ? events.first.startTime.month : reference.month,
        events.isNotEmpty ? events.first.startTime.day : reference.day,
      );
      final start = startMid.add(Duration(minutes: seg.startMinutes));
      final end = startMid.add(Duration(minutes: seg.endMinutes));
      entries.add(_DayRow(
        startSort: start,
        leftLabel: '— / —',
        timeLabel: '${_hhmm(start)}–${_hhmm(end)}',
        durationLabel: AnalyticsFormat.onlyMinutes(seg.durationMinutes),
        quantityLabel: '—',
        description: 'Простой',
        badgeColor: AnalyticsColors.tlIdle,
        badgeLabel: 'Простой',
      ));
    }

    entries.sort((a, b) => a.startSort.compareTo(b.startSort));

    return entries.map((row) {
      return TableRow(
        decoration: BoxDecoration(
          color: AnalyticsColors.card2.withOpacity(0.55),
        ),
        children: [
          Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  margin: const EdgeInsets.only(bottom: 4),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: row.badgeColor.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    row.badgeLabel,
                    style: TextStyle(
                      color: row.badgeColor,
                      fontSize: 10,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                Text(
                  row.leftLabel,
                  style: const TextStyle(
                    color: AnalyticsColors.text,
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
          _cell(row.timeLabel),
          _cell(row.durationLabel),
          _cell(row.quantityLabel),
          _cell(row.description, maxLines: 3, isMuted: true),
        ],
      );
    }).toList();
  }

  Widget _cell(String value, {int maxLines = 2, bool isMuted = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
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
    return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }
}

class _DayRow {
  final DateTime startSort;
  final String leftLabel;
  final String timeLabel;
  final String durationLabel;
  final String quantityLabel;
  final String description;
  final Color badgeColor;
  final String badgeLabel;

  const _DayRow({
    required this.startSort,
    required this.leftLabel,
    required this.timeLabel,
    required this.durationLabel,
    required this.quantityLabel,
    required this.description,
    required this.badgeColor,
    required this.badgeLabel,
  });
}
