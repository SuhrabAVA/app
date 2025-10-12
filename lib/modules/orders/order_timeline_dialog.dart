import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../personnel/personnel_provider.dart';
import 'order_model.dart';

/// Диалог, показывающий ход выполнения заказа на основе комментариев этапов.
class OrderTimelineDialog extends StatelessWidget {
  final OrderModel order;
  final List<Map<String, dynamic>> events;

  const OrderTimelineDialog({
    super.key,
    required this.order,
    required this.events,
  });

  static final DateFormat _dateTimeFormat = DateFormat('dd.MM.yyyy HH:mm');

  DateTime? _parseTimestamp(dynamic value) {
    if (value == null) return null;
    if (value is DateTime) return value;
    if (value is int) {
      if (value > 2000000000) {
        return DateTime.fromMillisecondsSinceEpoch(value);
      }
      return DateTime.fromMillisecondsSinceEpoch(value * 1000);
    }
    if (value is num) {
      return _parseTimestamp(value.toInt());
    }
    if (value is String) {
      if (value.isEmpty) return null;
      final parsedInt = int.tryParse(value);
      if (parsedInt != null) {
        return _parseTimestamp(parsedInt);
      }
      return DateTime.tryParse(value);
    }
    return null;
  }

  String _formatTimestamp(dynamic value) {
    final dt = _parseTimestamp(value);
    if (dt == null) return '';
    return _dateTimeFormat.format(dt);
  }

  String _formatQuantity(String text, double? parsed) {
    if (parsed != null) {
      final bool isInt = (parsed - parsed.round()).abs() < 0.0001;
      final display = isInt ? parsed.round().toString() : parsed.toStringAsFixed(2);
      return '$display шт.';
    }
    final trimmed = text.trim();
    if (trimmed.isEmpty) return '—';
    final normalised = trimmed.replaceAll(',', '.');
    final numeric = double.tryParse(normalised);
    if (numeric != null) {
      return _formatQuantity('', numeric);
    }
    return trimmed;
  }

  String _describeComment(String type, String text, double? quantity) {
    switch (type) {
      case 'start':
        return 'Начал(а) этап';
      case 'pause':
        return text.isEmpty ? 'Пауза' : 'Пауза: $text';
      case 'resume':
        return 'Возобновил(а) этап';
      case 'user_done':
        return 'Завершил(а) этап';
      case 'problem':
        return text.isEmpty ? 'Сообщил(а) о проблеме' : 'Проблема: $text';
      case 'setup_start':
        return 'Начал(а) настройку станка';
      case 'setup_done':
        return 'Завершил(а) настройку станка';
      case 'quantity_done':
        return 'Выполнил(а): ${_formatQuantity(text, quantity)}';
      case 'quantity_team_total':
        return 'Команда выполнила: ${_formatQuantity(text, quantity)}';
      case 'quantity_share':
        return 'Доля участника: ${_formatQuantity(text, quantity)}';
      case 'finish_note':
        return text.isEmpty
            ? 'Комментарий к завершению'
            : 'Комментарий к завершению: $text';
      case 'joined':
        return 'Присоединился(лась) к этапу';
      case 'exec_mode':
        final normalised = text.toLowerCase();
        if (normalised.contains('joint') || normalised.contains('совмест')) {
          return 'Режим: совместное исполнение';
        }
        return 'Режим: отдельный исполнитель';
      case 'msg':
        return text.isEmpty ? 'Комментарий' : text;
      default:
        return text.isEmpty ? type : text;
    }
  }

  String _describeOrderEvent(String type, String description) {
    if (description.isNotEmpty) return description;
    final lower = type.toLowerCase();
    switch (lower) {
      case 'created':
      case 'создание':
        return 'Заказ создан';
      case 'updated':
      case 'обновление':
        return 'Заказ обновлён';
      case 'deleted':
      case 'удаление':
        return 'Заказ удалён';
      default:
        return type.isEmpty ? 'Событие заказа' : type;
    }
  }

  String _orderEventTitle(String type) {
    if (type.isEmpty) return 'Событие заказа';
    final lower = type.toLowerCase();
    switch (lower) {
      case 'created':
      case 'создание':
        return 'Создание заказа';
      case 'updated':
      case 'обновление':
        return 'Обновление заказа';
      case 'deleted':
      case 'удаление':
        return 'Удаление заказа';
      default:
        return type;
    }
  }

  String _userDisplay(PersonnelProvider provider, String? userId) {
    if (userId == null || userId.isEmpty) return '';
    try {
      final emp = provider.employees.firstWhere((e) => e.id == userId);
      final full = '${emp.firstName} ${emp.lastName}'.trim();
      return full.isNotEmpty ? full : userId;
    } catch (_) {
      return userId;
    }
  }

  String _stageDisplay(PersonnelProvider provider, String? stageId) {
    if (stageId == null || stageId.isEmpty) return '';
    try {
      final wp = provider.workplaces.firstWhere((w) => w.id == stageId);
      return wp.name.isNotEmpty ? wp.name : stageId;
    } catch (_) {
      return stageId;
    }
  }

  Widget _buildEventTile(
      BuildContext context, Map<String, dynamic> event, PersonnelProvider personnel) {
    final source = (event['source'] ?? 'order_event').toString();
    final bool isComment = source == 'task_comment';
    final dynamic timestampRaw = event['timestamp'] ?? event['created_at'];
    final String timeLabel = _formatTimestamp(timestampRaw);
    final String userLabel = _userDisplay(personnel, event['user_id'] as String?);
    final String stageLabel =
        isComment ? _stageDisplay(personnel, event['stage_id'] as String?) : '';

    final List<String> metaParts = [];
    if (timeLabel.isNotEmpty) metaParts.add(timeLabel);
    if (userLabel.isNotEmpty) metaParts.add(userLabel);
    final String meta = metaParts.join(' • ');

    final double? quantity =
        (event['quantity'] is num) ? (event['quantity'] as num).toDouble() : null;
    final String eventType = (event['event_type'] ?? '').toString();
    final String description = (event['description'] ?? '').toString();

    final String titleText = isComment
        ? (stageLabel.isNotEmpty ? stageLabel : 'Комментарий к этапу')
        : _orderEventTitle(eventType);
    final String bodyText = isComment
        ? _describeComment(eventType, description, quantity)
        : _describeOrderEvent(eventType, description);

    final List<Widget> subtitleWidgets = [];
    if (meta.isNotEmpty) {
      subtitleWidgets.add(
        Text(meta, style: const TextStyle(fontSize: 12, color: Colors.black54)),
      );
      subtitleWidgets.add(const SizedBox(height: 2));
    }
    subtitleWidgets.add(Text(bodyText));

    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      title: Text(
        titleText,
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: subtitleWidgets,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final personnel = context.watch<PersonnelProvider>();
    final List<Map<String, dynamic>> sortedEvents =
        List<Map<String, dynamic>>.from(events);
    sortedEvents.sort((a, b) {
      final int tsA = (a['timestamp'] as int?) ?? 0;
      final int tsB = (b['timestamp'] as int?) ?? 0;
      return tsA.compareTo(tsB);
    });

    return AlertDialog(
      title: Text('Выполнение заказа ${order.id}'),
      content: SizedBox(
        width: double.maxFinite,
        child: sortedEvents.isEmpty
            ? const Text('Комментариев по выполнению пока нет')
            : ListView.separated(
                shrinkWrap: true,
                itemCount: sortedEvents.length,
                separatorBuilder: (_, __) => const Divider(height: 16),
                itemBuilder: (_, index) =>
                    _buildEventTile(context, sortedEvents[index], personnel),
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
