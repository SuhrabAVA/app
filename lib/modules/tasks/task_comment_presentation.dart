import 'package:flutter/material.dart';

import 'quantity_status_service.dart';
import 'task_model.dart';
import 'workspace_design.dart';

/// Общее представление комментариев `tasks.comments` для всех экранов.
///
/// Эталон текста, иконок и раскладки — панель «Комментарии» рабочего
/// пространства сотрудника (tasks_screen). Здесь только чтение/отображение:
/// запись и структура комментариев не затрагиваются.

/// Служебные типы-флаги состояния. Скрываются в лентах, где показывать их
/// отдельной строкой бессмысленно (решение МУПЗ); рабочее пространство
/// показывает их осмысленной фразой — см. [describeTaskComment].
const Set<String> kTaskCommentServiceTypes = <String>{
  'shift_pause_state',
  'exec_mode',
  'exec_mode_stage',
};

/// Типы количественных записей (для статусной подсветки).
const Set<String> kTaskCommentQuantityTypes = <String>{
  'quantity_done',
  'quantity_team_total',
  'quantity_share',
};

/// Формат времени комментария — как в рабочем пространстве.
///
/// `dd.MM HH:mm:ss` для текущего года и `dd.MM.yyyy HH:mm:ss` для любого
/// другого: без года задание прошлого ноября выглядело сегодняшним.
/// Секунды нормализуются к миллисекундам.
///
/// [reference] задаёт «сегодня» — нужен только тестам.
String formatTaskCommentTimestamp(int? ts, {DateTime? reference}) {
  if (ts == null || ts <= 0) return '';
  try {
    final dt = DateTime.fromMillisecondsSinceEpoch(normalizeEpochToMillis(ts));
    String two(int n) => n.toString().padLeft(2, '0');
    final currentYear = (reference ?? DateTime.now()).year;
    final date = dt.year == currentYear
        ? '${two(dt.day)}.${two(dt.month)}'
        : '${two(dt.day)}.${two(dt.month)}.${dt.year}';
    return '$date ${two(dt.hour)}:${two(dt.minute)}:${two(dt.second)}';
  } catch (_) {
    return '';
  }
}

String _formatQuantityDisplay(String raw) {
  final payloadText = quantityDisplayText(raw);
  final trimmed = payloadText.trim();
  if (trimmed.isEmpty) return '0';
  final numeric = RegExp(r'^[0-9]+([.,][0-9]+)?$');
  if (!numeric.hasMatch(trimmed)) return trimmed;
  final normalised = trimmed.replaceAll(',', '.');
  final value = double.tryParse(normalised);
  if (value == null) return trimmed;
  if ((value - value.round()).abs() < 0.0001) {
    return '${value.round()} шт.';
  }
  return '${value.toStringAsFixed(2)} шт.';
}

String _timeTypeLabel(TaskTimeType type) {
  switch (type) {
    case TaskTimeType.production:
      return 'Производство';
    case TaskTimeType.pause:
      return 'Пауза';
    case TaskTimeType.problem:
      return 'Проблема';
    case TaskTimeType.shiftChange:
      return 'Пересмена';
    case TaskTimeType.setup:
      return 'Наладка';
  }
}

String _formatEventTime(DateTime dt) {
  final local = dt.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(local.day)}.${two(local.month)}.${local.year} ${two(local.hour)}:${two(local.minute)}';
}

/// Человекочитаемое описание интервального события `time_event`
/// («Производство: 10.07.2026 10:00 — в процессе · Иванов Иван · заметка»).
/// Возвращает null, если текст не является пейлоадом TaskTimeEvent.
String? describeTaskTimeEventPayload(
  String text, {
  String Function(String userId)? resolveUserName,
}) {
  final parsed = TaskTimeEvent.fromPayload(text, '', 0, '');
  if (parsed == null) return null;

  final started = _formatEventTime(parsed.startTime);
  final ended =
      parsed.endTime == null ? 'в процессе' : _formatEventTime(parsed.endTime!);
  String nameOf(String userId) {
    if (userId.isEmpty) return '';
    final resolved = resolveUserName?.call(userId) ?? '';
    return resolved.isNotEmpty ? resolved : userId;
  }

  final subject = nameOf(parsed.subjectUserId);
  final initiator = nameOf(parsed.initiatedBy);
  final note = (parsed.note ?? '').trim();

  final parts = <String>[
    '${_timeTypeLabel(parsed.type)}: $started — $ended',
    if (subject.isNotEmpty) subject,
    if (initiator.isNotEmpty && initiator != subject) 'Инициатор: $initiator',
    if (note.isNotEmpty) note,
  ];
  return parts.join(' · ');
}

bool _looksLikeJson(String text) {
  final trimmed = text.trim();
  return trimmed.startsWith('{') && trimmed.endsWith('}');
}

/// Локализованное описание комментария/события этапа. Эталонный switch
/// рабочего пространства, дополненный `time_event` и защитой от сырого JSON.
String describeTaskComment(
  String type,
  String text, {
  String Function(String userId)? resolveUserName,
}) {
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
      return 'Начал(а) наладку';
    case 'setup_resume':
      return 'Продолжил(а) наладку';
    case 'setup_done':
      return 'Завершил(а) наладку';
    case 'quantity_done':
      return 'Выполнил(а): ${_formatQuantityDisplay(text)}';
    case 'quantity_team_total':
      return 'Команда выполнила: ${_formatQuantityDisplay(text)}';
    case 'quantity_share':
      return 'Доля участника: ${_formatQuantityDisplay(text)}';
    case 'finish_note':
      return text.isEmpty
          ? 'Комментарий к завершению'
          : 'Комментарий к завершению: $text';
    case 'joined':
      return 'Присоединился(лась) к этапу';
    case 'helper_removed':
      return text.isNotEmpty ? text : 'Помощник удалён с этапа';
    case 'helper_removed_qty':
      return text.isNotEmpty
          ? 'Количество удалённого помощника: $text'
          : 'Количество удалённого помощника зафиксировано';
    case 'exec_mode':
    case 'exec_mode_stage':
      final t = text.toLowerCase();
      final bool isJoint = t.contains('joint') || t.contains('помощ');
      final bool isSeparate =
          !isJoint && (t.contains('separ') || t.contains('отдель'));
      if (isSeparate) {
        return 'Режим: отдельный исполнитель';
      }
      return 'Режим: одиночная или совместная работа';
    case 'shift_pause':
      return text.isNotEmpty ? text : 'Пересмена: этап приостановлен';
    case 'shift_resume':
      return text.isNotEmpty ? text : 'Пересмена: работа возобновлена';
    case 'shift_pause_state':
      return 'Состояние для пересмены сохранено';
    case 'ink_writeoff':
      return text.isNotEmpty ? text : 'Зафиксировано списание краски';
    case 'time_event':
      return describeTaskTimeEventPayload(text,
              resolveUserName: resolveUserName) ??
          'Служебная запись';
    default:
      if (text.trim().isEmpty) return 'Без комментария';
      // Никогда не показываем пользователю сырой JSON-пейлоад.
      if (_looksLikeJson(text)) {
        return describeTaskTimeEventPayload(text,
                resolveUserName: resolveUserName) ??
            'Служебная запись';
      }
      return text;
  }
}

/// Иконка типа события — эталонный набор рабочего пространства.
IconData taskCommentIcon(String type) {
  if (kTaskCommentQuantityTypes.contains(type)) {
    return Icons.check_circle_outline;
  }
  switch (type) {
    case 'problem':
      return Icons.error_outline;
    case 'pause':
      return Icons.pause_circle_outline;
    case 'setup_start':
    case 'setup_resume':
    case 'setup_done':
      return Icons.build_outlined;
    case 'joined':
      return Icons.group_add_outlined;
    case 'exec_mode':
    case 'exec_mode_stage':
      return Icons.settings_input_component_outlined;
    case 'shift_pause':
      return Icons.pause_circle_outline;
    case 'shift_resume':
      return Icons.play_circle_outline;
    default:
      return Icons.info_outline;
  }
}

/// Цвет типа события. Для количественных записей берёт статус из
/// сохранённого пейлоада (если есть); экраны с контекстом заказа могут
/// передать свой цвет через [TaskCommentTile.accentColor].
Color taskCommentColor(String type, [String text = '']) {
  if (kTaskCommentQuantityTypes.contains(type)) {
    final status = quantityStatusFromText(text);
    return status == null ? Colors.blueGrey : getQuantityStatusColor(status);
  }
  switch (type) {
    case 'problem':
      return Colors.redAccent;
    case 'pause':
      return Colors.orange;
    case 'setup_start':
    case 'setup_resume':
    case 'setup_done':
      return Colors.indigo;
    case 'joined':
      return Colors.teal;
    case 'exec_mode':
    case 'exec_mode_stage':
      return Colors.purple;
    case 'shift_pause':
    case 'shift_resume':
      return Colors.deepPurple;
    default:
      return Colors.blueGrey;
  }
}

/// Строка комментария в эталонной раскладке рабочего пространства:
/// иконка + заголовок «время • автор • Этап: имя» + описание + вложения.
class TaskCommentTile extends StatelessWidget {
  const TaskCommentTile({
    super.key,
    required this.comment,
    this.authorName,
    this.stageName,
    this.scale = 1.0,
    this.attachments = const <Widget>[],
    this.accentColor,
    this.iconOverride,
    this.textColor,
    this.resolveUserName,
    this.workspaceStyle = false,
  });

  final TaskComment comment;
  final String? authorName;
  final String? stageName;
  final double scale;

  /// Готовые чипы вложений (экраны сохраняют собственный вид чипов).
  final List<Widget> attachments;

  /// Переопределение цвета иконки (например, статус количества).
  final Color? accentColor;
  final IconData? iconOverride;

  /// Переопределение цвета текста описания.
  final Color? textColor;

  /// Резолвер имён для описаний time_event.
  final String Function(String userId)? resolveUserName;
  final bool workspaceStyle;

  @override
  Widget build(BuildContext context) {
    final icon = iconOverride ?? taskCommentIcon(comment.type);
    final color = accentColor ?? taskCommentColor(comment.type, comment.text);

    final headerParts = <String>[];
    final ts = formatTaskCommentTimestamp(comment.timestamp);
    if (ts.isNotEmpty) headerParts.add(ts);
    final author = (authorName ?? '').trim();
    if (author.isNotEmpty) headerParts.add(author);
    final stage = (stageName ?? '').trim();
    if (stage.isNotEmpty) headerParts.add('Этап: $stage');
    final header = headerParts.join(' • ');

    final description = describeTaskComment(
      comment.type,
      comment.text,
      resolveUserName: resolveUserName,
    );

    if (workspaceStyle) {
      final initial = author.isEmpty ? '•' : author[0].toUpperCase();
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 28,
              height: 28,
              margin: const EdgeInsets.only(top: 2),
              alignment: Alignment.center,
              decoration: const BoxDecoration(
                color: WorkspaceColors.primary,
                shape: BoxShape.circle,
              ),
              child: Text(
                initial,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (header.isNotEmpty)
                    Text(
                      header,
                      style: const TextStyle(
                        color: WorkspaceColors.mutedForeground,
                        fontSize: 12,
                        height: 1.25,
                      ),
                    ),
                  const SizedBox(height: 2),
                  Text(
                    description,
                    style: TextStyle(
                      color: textColor ?? WorkspaceColors.foreground,
                      fontSize: 14,
                      height: 1.25,
                    ),
                  ),
                  if (attachments.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: attachments,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    return Padding(
      padding: EdgeInsets.symmetric(vertical: scale * 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: scale * 16, color: color),
          SizedBox(width: scale * 3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (header.isNotEmpty)
                  Text(
                    header,
                    style: TextStyle(
                      fontSize: scale * 9.5,
                      color: Colors.grey,
                    ),
                  ),
                Text(
                  description,
                  style: TextStyle(
                    fontSize: scale * 12.5,
                    color: textColor ?? Colors.black87,
                  ),
                ),
                if (attachments.isNotEmpty)
                  Padding(
                    padding: EdgeInsets.only(top: scale * 6),
                    child: Wrap(
                      spacing: scale * 6,
                      runSpacing: scale * 6,
                      children: attachments,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
