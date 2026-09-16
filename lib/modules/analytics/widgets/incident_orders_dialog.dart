import 'package:flutter/material.dart';

import '../../../utils/kostanay_time.dart';
import '../../tasks/task_comment_presentation.dart';
import '../models/analytics_day_comment.dart';
import '../models/analytics_event.dart';
import '../utils/format_utils.dart';

/// Разбор простоев рабочего места: какие заказы стояли и почему.
///
/// Первый уровень — заказы, в которых у сотрудника были паузы (или проблемы)
/// на этом рабочем месте. Второй уровень — комментарии заказа целиком, в том
/// же виде, что и в таблице дня (`DayEventsTable._showComments`): иконка типа,
/// время, автор, рабочее место и расшифровка. Записи, попавшие в интервал
/// простоя, подсвечены — причину обычно пишут в соседних сообщениях.
class IncidentOrdersDialog extends StatelessWidget {
  const IncidentOrdersDialog({
    super.key,
    required this.title,
    required this.workplaceName,
    required this.type,
    required this.events,
    required this.comments,
    required this.employeeNameOf,
    required this.workplaceNameOf,
  });

  /// «Паузы» / «Проблемы».
  final String title;
  final String workplaceName;
  final AnalyticsEventType type;

  /// События простоя — уже отфильтрованы по сотруднику и рабочему месту.
  final List<AnalyticsEvent> events;

  /// Все комментарии периода (по всем заказам) — нужны для второго уровня.
  final List<AnalyticsDayComment> comments;

  final String Function(String userId) employeeNameOf;
  final String Function(String workplaceId) workplaceNameOf;

  @override
  Widget build(BuildContext context) {
    // Группируем по заказу: заказов немного, событий по каждому — больше.
    final byOrder = <String, List<AnalyticsEvent>>{};
    for (final e in events) {
      byOrder.putIfAbsent(e.orderId, () => []).add(e);
    }
    final orders = byOrder.entries.toList()
      ..sort((a, b) {
        final aMin = a.value.fold<int>(0, (s, e) => s + e.durationMinutes());
        final bMin = b.value.fold<int>(0, (s, e) => s + e.durationMinutes());
        return bMin.compareTo(aMin);
      });

    return AlertDialog(
      title: Text('$title — $workplaceName'),
      content: SizedBox(
        width: 460,
        child: orders.isEmpty
            ? const Text('Нет записей за выбранный период')
            : ListView(
                shrinkWrap: true,
                children: [
                  for (final entry in orders)
                    _orderTile(context, entry.key, entry.value),
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Закрыть'),
        ),
      ],
    );
  }

  Widget _orderTile(
      BuildContext context, String orderId, List<AnalyticsEvent> list) {
    list.sort((a, b) => a.startTime.compareTo(b.startTime));
    final minutes = list.fold<int>(0, (s, e) => s + e.durationMinutes());
    final customer = list
        .map((e) => e.customer)
        .firstWhere((c) => c != null && c.trim().isNotEmpty, orElse: () => null);
    final label = (customer != null && customer.trim().isNotEmpty)
        ? customer.trim()
        : 'Заказ ${orderId.length > 8 ? orderId.substring(0, 8) : orderId}';

    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      leading: Icon(
        type == AnalyticsEventType.problem
            ? Icons.error_outline
            : Icons.pause_circle_outline,
        color: type == AnalyticsEventType.problem
            ? Colors.red
            : Colors.orange,
      ),
      title: Text(label),
      subtitle: Text(
        '${list.length} · ${AnalyticsFormat.hoursMinutes(minutes)} · '
        'первый случай ${_dateTime(list.first.startTime)}',
        style: const TextStyle(fontSize: 12),
      ),
      trailing: const Icon(Icons.chevron_right, size: 20),
      onTap: () => showDialog<void>(
        context: context,
        builder: (_) => OrderCommentsDialog(
          orderId: orderId,
          customer: customer,
          incidents: list,
          comments:
              comments.where((c) => c.orderId == orderId).toList(),
          employeeNameOf: employeeNameOf,
          workplaceNameOf: workplaceNameOf,
        ),
      ),
    );
  }
}

/// Комментарии одного заказа — как в таблице дня, с подсветкой простоя.
class OrderCommentsDialog extends StatelessWidget {
  const OrderCommentsDialog({
    super.key,
    required this.orderId,
    required this.customer,
    required this.incidents,
    required this.comments,
    required this.employeeNameOf,
    required this.workplaceNameOf,
  });

  final String orderId;
  final String? customer;

  /// Интервалы простоя, ради которых открыли заказ.
  final List<AnalyticsEvent> incidents;
  final List<AnalyticsDayComment> comments;
  final String Function(String userId) employeeNameOf;
  final String Function(String workplaceId) workplaceNameOf;

  /// Комментарий попал в интервал простоя (с запасом в минуту по краям —
  /// метка события и сообщение о причине редко совпадают до секунды).
  bool _isDuringIncident(AnalyticsDayComment c) {
    for (final e in incidents) {
      final from = e.startTime.subtract(const Duration(minutes: 1));
      final to =
          (e.endTime ?? nowInKostanay()).add(const Duration(minutes: 1));
      if (!c.timestamp.isBefore(from) && !c.timestamp.isAfter(to)) return true;
    }
    return false;
  }

  String _describe(AnalyticsDayComment c) {
    final author = employeeNameOf(c.userId);
    final wp = workplaceNameOf(c.workplaceId);
    final parts = <String>[
      _hhmm(c.timestamp),
      if (author.isNotEmpty) author,
      if (wp.isNotEmpty) wp,
    ];
    final description = describeTaskComment(
      c.type,
      c.text,
      resolveUserName: employeeNameOf,
    );
    return '${parts.join(' · ')} — $description';
  }

  @override
  Widget build(BuildContext context) {
    final sorted = [...comments]
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    final label = (customer != null && customer!.trim().isNotEmpty)
        ? customer!.trim()
        : 'Заказ ${orderId.length > 8 ? orderId.substring(0, 8) : orderId}';

    return AlertDialog(
      title: Text('Комментарии — $label'),
      content: SizedBox(
        width: 460,
        child: sorted.isEmpty
            ? const Text('Нет комментариев')
            : ListView(
                shrinkWrap: true,
                children: [
                  for (final c in sorted)
                    Container(
                      margin: const EdgeInsets.symmetric(vertical: 2),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 4),
                      decoration: _isDuringIncident(c)
                          ? BoxDecoration(
                              color: taskCommentColor(c.type, c.text)
                                  .withOpacity(0.10),
                              borderRadius: BorderRadius.circular(8),
                            )
                          : null,
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            taskCommentIcon(c.type),
                            size: 16,
                            color: taskCommentColor(c.type, c.text),
                          ),
                          const SizedBox(width: 6),
                          Expanded(child: Text(_describe(c))),
                        ],
                      ),
                    ),
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Закрыть'),
        ),
      ],
    );
  }
}

String _hhmm(DateTime dt) =>
    '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';

String _dateTime(DateTime dt) =>
    '${dt.day.toString().padLeft(2, '0')}.${dt.month.toString().padLeft(2, '0')} '
    '${_hhmm(dt)}';
