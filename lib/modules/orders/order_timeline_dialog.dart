import 'package:flutter/material.dart';

import '../tasks/workspace_design.dart';
import 'dart:convert';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../utils/kostanay_time.dart';
import '../personnel/personnel_provider.dart';
import '../tasks/task_comment_presentation.dart';
import '../tasks/task_model.dart';
import 'order_comment_attachment.dart';
import 'order_comments_repository.dart';
import 'order_comments_timeline.dart';
import 'order_generation_switcher.dart';
import 'order_model.dart';
import 'order_restart_history_repository.dart';
import 'restart_history_service.dart';

/// Лента истории заказа: события самого заказа, комментарии этапов и чат.
///
/// Раньше жила только внутри отдельного диалога «часов» в списке заказов.
/// Диалог убран — история встроена в карточку заказа, поэтому лента вынесена
/// в самостоятельный виджет и не тянет за собой оформление окна.
///
/// [showGenerationSwitcher] включает переключатель поколений цепочки
/// возобновлений: каждая кнопка открывает историю именно того поколения
/// (только просмотр), ничего не сливается в один список.
class OrderHistoryView extends StatefulWidget {
  final OrderModel order;

  /// Загрузка истории произвольного поколения (обычно
  /// `OrdersProvider.fetchOrderHistory`).
  final Future<List<Map<String, dynamic>>> Function(String orderId) loadEvents;

  /// Уже загруженные события текущего заказа — чтобы не ждать запрос дважды.
  final List<Map<String, dynamic>>? initialEvents;

  final RestartHistoryService? historyService;

  final bool showGenerationSwitcher;

  const OrderHistoryView({
    super.key,
    required this.order,
    required this.loadEvents,
    this.initialEvents,
    this.historyService,
    this.showGenerationSwitcher = true,
  });

  @override
  State<OrderHistoryView> createState() => _OrderHistoryViewState();
}

class _OrderHistoryViewState extends State<OrderHistoryView> {
  List<OrderGenerationEntry> _generations = const [];
  bool _loadingGenerations = false;
  late String _selectedOrderId;
  // Ленивая загрузка: future истории поколения создаётся при первом выборе.
  final Map<String, Future<List<Map<String, dynamic>>>> _eventsByOrderId = {};
  // Вложения комментариев этапов: comment_id -> файлы.
  final Map<String, List<OrderCommentAttachment>> _attachmentsByComment = {};
  final Set<String> _requestedAttachmentCommentIds = <String>{};

  void _ensureCommentAttachments(List<Map<String, dynamic>> events) {
    final missing = <String>[];
    for (final event in events) {
      if ((event['source'] ?? '') != 'task_comment') continue;
      final id = (event['comment_id'] ?? '').toString().trim();
      if (id.isEmpty || _requestedAttachmentCommentIds.contains(id)) continue;
      _requestedAttachmentCommentIds.add(id);
      missing.add(id);
    }
    if (missing.isEmpty) return;
    Future.microtask(() async {
      try {
        final rows =
            await OrderCommentsRepository().loadAttachmentsByCommentIds(missing);
        if (!mounted || rows.isEmpty) return;
        setState(() {
          for (final a in rows) {
            _attachmentsByComment
                .putIfAbsent(a.commentId, () => <OrderCommentAttachment>[])
                .add(a);
          }
        });
      } catch (_) {
        // Вложения не критичны для истории.
      }
    });
  }

  static final DateFormat _dateTimeFormat = DateFormat('dd.MM.yyyy в HH:mm', 'ru');

  @override
  void initState() {
    super.initState();
    _selectedOrderId = widget.order.id;
    final seeded = widget.initialEvents;
    if (seeded != null) {
      _eventsByOrderId[widget.order.id] = Future.value(seeded);
    }
    if (widget.showGenerationSwitcher) {
      _loadGenerations();
    }
  }

  Future<void> _loadGenerations() async {
    setState(() => _loadingGenerations = true);
    final service = widget.historyService ??
        RestartHistoryService(SupabaseOrderRestartHistoryRepository());
    final chain = await service.loadGenerationChain(widget.order.id);
    if (!mounted) return;
    setState(() {
      _generations = chain;
      _loadingGenerations = false;
    });
  }

  Future<List<Map<String, dynamic>>> _eventsFor(String orderId) {
    return _eventsByOrderId.putIfAbsent(
      orderId,
      () => widget.loadEvents(orderId),
    );
  }

  DateTime? _parseTimestamp(dynamic value) {
    if (value == null) return null;
    if (value is DateTime) return value;
    if (value is int) {
      return DateTime.fromMillisecondsSinceEpoch(normalizeEpochToMillis(value));
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
    // Метки хранятся в UTC — показываем в Костанайском времени (UTC+5),
    // независимо от таймзоны устройства.
    return _dateTimeFormat.format(toKostanayTime(dt));
  }

  String _describeOrderEvent(String type, String description) {
    final formattedJson = _formatTechnicalPayload(description);
    if (formattedJson != null) return formattedJson;
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
      case 'produced_qty':
        return 'Обновлено произведённое количество';
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
      case 'produced_qty':
        return 'Произведено';
      case 'shipment':
        return 'Отгрузка';
      default:
        return type;
    }
  }

  String? _formatTechnicalPayload(String rawDescription) {
    final text = rawDescription.trim();
    if (!(text.startsWith('{') && text.endsWith('}'))) {
      return null;
    }
    try {
      final decoded = jsonDecode(text);
      if (decoded is! Map) return null;
      final map = Map<String, dynamic>.from(decoded);
      final String eventType = (map['type'] ?? '').toString().trim().toLowerCase();
      if (eventType.isEmpty) return null;
      if (eventType == 'setup') {
        final started = _formatTimestamp(map['startTime']);
        final ended = _formatTimestamp(map['endTime']);
        final who = (map['initiatedBy'] ?? '').toString();
        final workplace = (map['workplaceId'] ?? '').toString();
        final participants = map['participantsSnapshot'];
        final participantsText = participants is List
            ? participants.map((e) => e.toString()).where((e) => e.isNotEmpty).join(', ')
            : '';
        final parts = <String>[
          if (started.isNotEmpty) 'Наладка начата: $started',
          if (ended.isNotEmpty) 'Наладка завершена: $ended',
          if (who.isNotEmpty) 'Инициатор: $who',
          if (workplace.isNotEmpty) 'Рабочее место: $workplace',
          if (participantsText.isNotEmpty) 'Участники: $participantsText',
        ];
        return parts.isEmpty ? 'Событие наладки' : parts.join('\n');
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  String _userDisplay(PersonnelProvider provider, String? userId) {
    if (userId == null || userId.isEmpty) return '';
    // Техлид сотрудником не является: у него служебный id, и без этой ветки в
    // истории вместо автора стояло бы слово «tech_leader».
    if (userId == 'tech_leader') return 'Технический лидер';
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
    final bool isChat = source == 'chat_message';
    final dynamic timestampRaw = event['timestamp'] ?? event['created_at'];
    final String timeLabel = _formatTimestamp(timestampRaw);
    final String userLabel = _userDisplay(personnel, event['user_id'] as String?);

    final String eventType = (event['event_type'] ?? '').toString();
    final String description = (event['description'] ?? '').toString();

    // Комментарии этапов — эталонный тайл рабочего пространства
    // (иконка + время • автор • этап + описание + вложения).
    if (isComment) {
      final commentId = (event['comment_id'] ?? '').toString().trim();
      final attachments =
          _attachmentsByComment[commentId] ?? const <OrderCommentAttachment>[];
      return TaskCommentTile(
        comment: TaskComment(
          id: commentId,
          type: eventType,
          text: description,
          userId: (event['user_id'] ?? '').toString(),
          timestamp: (event['timestamp'] as int?) ?? 0,
        ),
        authorName: userLabel,
        stageName: _stageDisplay(personnel, event['stage_id'] as String?),
        resolveUserName: (userId) => _userDisplay(personnel, userId),
        attachments: [
          for (final a in attachments) AttachmentPreview(attachment: a),
        ],
      );
    }

    final List<String> metaParts = [];
    if (timeLabel.isNotEmpty) metaParts.add(timeLabel);
    if (userLabel.isNotEmpty) metaParts.add(userLabel);
    final String meta = metaParts.join(' • ');

    final String titleText =
        isChat ? 'Чат заказа' : _orderEventTitle(eventType);
    final String bodyText = isChat
        ? (description.isEmpty ? 'Сообщение в чате' : description)
        : _describeOrderEvent(eventType, description);

    // Тот же язык, что у комментариев: цветной значок слева, шапка
    // «время • автор» серым, дальше содержание. Прежний ListTile выбивался из
    // ленты — заголовок, серая строка и абзац без единого акцента.
    final accent = _eventAccent(eventType, isChat: isChat);
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
            decoration: BoxDecoration(
              color: accent.background,
              shape: BoxShape.circle,
            ),
            child: Icon(accent.icon, size: 15, color: accent.color),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (meta.isNotEmpty)
                  Text(
                    meta,
                    style: const TextStyle(
                      fontSize: 11.5,
                      color: WorkspaceColors.mutedForeground,
                    ),
                  ),
                const SizedBox(height: 1),
                Text(
                  titleText,
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    color: accent.color,
                  ),
                ),
                const SizedBox(height: 3),
                // Каждая правка своей строкой: «Тираж: 1000 → 2000» читается
                // как таблица, а слитый абзац — нет.
                for (final line in const LineSplitter().convert(bodyText))
                  if (line.trim().isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 1),
                      child: _eventBodyLine(line.trim()),
                    ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Строка описания: подпись поля приглушена, значения — обычным текстом.
  Widget _eventBodyLine(String line) {
    final separator = line.indexOf(': ');
    if (separator <= 0) {
      return Text(
        line,
        style: const TextStyle(
          fontSize: 13,
          height: 1.35,
          color: WorkspaceColors.foreground,
        ),
      );
    }
    return Text.rich(
      TextSpan(children: [
        TextSpan(
          text: '${line.substring(0, separator + 1)} ',
          style: const TextStyle(
            fontSize: 13,
            height: 1.35,
            color: WorkspaceColors.mutedForeground,
          ),
        ),
        TextSpan(
          text: line.substring(separator + 2),
          style: const TextStyle(
            fontSize: 13,
            height: 1.35,
            color: WorkspaceColors.foreground,
          ),
        ),
      ]),
    );
  }

  /// Значок и цвет события. Ключ — тип, который пишет провайдер.
  _EventAccent _eventAccent(String type, {required bool isChat}) {
    if (isChat) {
      return const _EventAccent(
        Icons.chat_bubble_outline,
        WorkspaceColors.blue,
        WorkspaceColors.blueBackground,
      );
    }
    switch (type.toLowerCase()) {
      case 'создание':
      case 'created':
        return const _EventAccent(
          Icons.add_circle_outline,
          WorkspaceColors.success,
          WorkspaceColors.successBackground,
        );
      case 'изменение заказа':
        return const _EventAccent(
          Icons.edit_outlined,
          WorkspaceColors.setup,
          WorkspaceColors.setupBackground,
        );
      case 'изменение бумаги':
      case 'резерв бумаги':
        return const _EventAccent(
          Icons.description_outlined,
          WorkspaceColors.blue,
          WorkspaceColors.blueBackground,
        );
      case 'изменение опций':
        return const _EventAccent(
          Icons.tune,
          WorkspaceColors.warning,
          WorkspaceColors.warningBackground,
        );
      case 'отгрузка':
      case 'shipment':
        return const _EventAccent(
          Icons.local_shipping_outlined,
          WorkspaceColors.success,
          WorkspaceColors.successBackground,
        );
      case 'удаление':
      case 'deleted':
        return const _EventAccent(
          Icons.delete_outline,
          WorkspaceColors.danger,
          WorkspaceColors.secondaryBackground,
        );
      default:
        return const _EventAccent(
          Icons.history,
          WorkspaceColors.mutedForeground,
          WorkspaceColors.secondaryBackground,
        );
    }
  }

  Widget _buildEventsList(BuildContext context, PersonnelProvider personnel) {
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: _eventsFor(_selectedOrderId),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        if (snapshot.hasError) {
          return Text('Ошибка загрузки истории: ${snapshot.error}');
        }
        final List<Map<String, dynamic>> sortedEvents =
            List<Map<String, dynamic>>.from(snapshot.data ?? const []);
        sortedEvents.sort((a, b) {
          final int tsA = (a['timestamp'] as int?) ?? 0;
          final int tsB = (b['timestamp'] as int?) ?? 0;
          return tsA.compareTo(tsB);
        });
        _ensureCommentAttachments(sortedEvents);
        if (sortedEvents.isEmpty) {
          return const Text('Комментариев по выполнению пока нет');
        }
        // Прокрутку ленты делает этот список, поэтому shrinkWrap здесь не
        // нужен: он растягивал ListView на всю высоту содержимого, скроллить
        // становилось нечего, а жест внешнему скроллу уже не доставался.
        return Scrollbar(
          thumbVisibility: true,
          child: ListView.separated(
            padding: const EdgeInsets.only(bottom: 12),
            itemCount: sortedEvents.length,
            separatorBuilder: (_, __) => const Divider(height: 16),
            itemBuilder: (_, index) =>
                _buildEventTile(context, sortedEvents[index], personnel),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final personnel = context.watch<PersonnelProvider>();

    // Виджету нужна ограниченная высота: ленту прокручивает собственный
    // список, а не внешний скролл. Единственное место использования —
    // панель комментариев в карточке МУПЗ — высоту задаёт.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.showGenerationSwitcher)
          OrderGenerationSwitcher(
            generations: _generations,
            currentOrderId: widget.order.id,
            selectedOrderId: _selectedOrderId,
            loading: _loadingGenerations,
            currentLabel: 'Этот заказ',
            // История и так только для просмотра.
            readOnlyNotice: null,
            onSelected: (orderId) =>
                setState(() => _selectedOrderId = orderId),
          ),
        Expanded(child: _buildEventsList(context, personnel)),
      ],
    );
  }
}

/// Значок события истории: иконка, её цвет и заливка кружка.
class _EventAccent {
  const _EventAccent(this.icon, this.color, this.background);

  final IconData icon;
  final Color color;
  final Color background;
}
