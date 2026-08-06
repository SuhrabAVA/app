import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:provider/provider.dart';

import '../tasks/workspace_design.dart';
import 'chat_provider.dart';
import 'widgets/input_bar.dart';
import 'widgets/message_bubble.dart';

class ChatScreen extends StatefulWidget {
  final String roomId;
  final String meId;
  final String? meName;
  final bool isLead; // техлид?
  final bool workspaceStyle;

  /// Тех-лидер/менеджер: может оформлять претензии из медиа-сообщений.
  final bool canCreateClaim;

  const ChatScreen({
    super.key,
    required this.roomId,
    required this.meId,
    this.meName,
    this.isLead = false,
    this.workspaceStyle = true,
    this.canCreateClaim = false,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  late ChatProvider _chat;
  bool _chatReady = false;
  final _scroll = ScrollController();

  Future<void> _subscribeToRoom() async {
    if (!_chatReady) return;
    try {
      await _chat.subscribe(widget.roomId);
    } catch (e, st) {
      debugPrint('Chat subscribe error: $e');
      debugPrint('$st');
    }
  }

  @override
  void initState() {
    super.initState();
    // Подписываемся в addPostFrame, чтобы гарантированно был доступен Provider
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_subscribeToRoom());
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Безопасно получаем ChatProvider при активном контексте
    _chat = context.read<ChatProvider>();
    _chatReady = true;
  }

  @override
  void dispose() {
    _scroll.dispose();
    // НЕ обращаемся к Provider через context в dispose() (чтобы избежать "deactivated widget's ancestor")
    if (_chatReady) {
      _chat.unsubscribe(widget.roomId);
    }
    super.dispose();
  }

  void _scrollToEnd() {
    if (!mounted || !_scroll.hasClients) return;
    _scroll.animateTo(
      _scroll.position.maxScrollExtent,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
  }

  void _exitChat() {
    final tabController = DefaultTabController.maybeOf(context);
    if (tabController != null && tabController.index != 0) {
      tabController.animateTo(0);
      return;
    }
    unawaited(Navigator.of(context).maybePop());
  }

  Future<void> _handleMenu(String value) async {
    final chat = context.read<ChatProvider>();
    switch (value) {
      case 'clear':
        final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Очистить чат?'),
            content: const Text('Все сообщения будут удалены.'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Отмена'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Очистить'),
              ),
            ],
          ),
        );
        if (ok == true) {
          await chat.clearRoom(widget.roomId);
        }
        break;
      case 'range':
        final range = await showDateRangePicker(
          context: context,
          firstDate: DateTime(2020),
          lastDate: DateTime.now(),
        );
        if (range != null) {
          await chat.deleteMessagesInRange(
            roomId: widget.roomId,
            from: range.start,
            to: range.end.add(const Duration(days: 1)),
          );
        }
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    assert(() {
      debugPaintBaselinesEnabled = false;
      return true;
    }());

    return DefaultTextStyle.merge(
      style: const TextStyle(
        decoration: TextDecoration.none,
        decorationColor: Colors.transparent,
        fontWeight: FontWeight.w400,
      ),
      child: Consumer<ChatProvider>(
        builder: (context, chat, _) {
          final list = chat.messages(widget.roomId);
          // автопрокрутка вниз при новых сообщениях
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            _scrollToEnd();
          });

          final media = MediaQuery.of(context);
          final bool isTablet =
              media.size.width < 1100 && media.size.shortestSide >= 600;
          final double scale = isTablet ? 0.9 : 1.0;
          double scaled(double value) => value * scale;

          Widget leadMenu() => PopupMenuButton<String>(
                onSelected: _handleMenu,
                itemBuilder: (ctx) => const [
                  PopupMenuItem(
                    value: 'clear',
                    child: Text('Очистить чат'),
                  ),
                  PopupMenuItem(
                    value: 'range',
                    child: Text('Удалить за период'),
                  ),
                ],
              );

          Widget backButton() => Tooltip(
                message: 'Назад',
                child: Material(
                  color: WorkspaceColors.secondaryBackground,
                  borderRadius: BorderRadius.circular(10),
                  child: InkWell(
                    onTap: _exitChat,
                    borderRadius: BorderRadius.circular(10),
                    hoverColor: WorkspaceColors.primary.withValues(alpha: 0.07),
                    focusColor: WorkspaceColors.primary.withValues(alpha: 0.10),
                    child: const SizedBox(
                      width: 38,
                      height: 38,
                      child: Icon(
                        Icons.arrow_back_rounded,
                        size: 20,
                        color: WorkspaceColors.foreground,
                      ),
                    ),
                  ),
                ),
              );

          final messagesAndInput = Column(
            children: [
              Expanded(
                child: list.isEmpty && widget.workspaceStyle
                    ? const WorkspaceEmptyState(
                        icon: Icons.forum_outlined,
                        title: 'Сообщений пока нет',
                        message: 'Начните разговор или отправьте вложение.',
                      )
                    : ListView.builder(
                        controller: _scroll,
                        padding: EdgeInsets.symmetric(
                          vertical: scaled(widget.workspaceStyle ? 12 : 8),
                        ),
                        itemCount: list.length,
                        itemBuilder: (context, i) {
                          final m = list[i];
                          final isMine = m.senderId == widget.meId;
                          return MessageBubble(
                            m: m,
                            isMine: isMine,
                            meId: widget.meId,
                            workspaceStyle: widget.workspaceStyle,
                          );
                        },
                      ),
              ),
              Container(
                decoration: widget.workspaceStyle
                    ? const BoxDecoration(
                        color: WorkspaceColors.surface,
                        border: Border(
                          top: BorderSide(color: WorkspaceColors.border),
                        ),
                      )
                    : null,
                padding: EdgeInsets.fromLTRB(
                  scaled(widget.workspaceStyle ? 12 : 8),
                  scaled(widget.workspaceStyle ? 10 : 0),
                  scaled(widget.workspaceStyle ? 12 : 8),
                  scaled(widget.workspaceStyle ? 12 : 8),
                ),
                child: ChatInputBar(
                  roomId: widget.roomId,
                  senderId: widget.meId,
                  senderName: widget.meName,
                  scale: scale,
                  compact: isTablet,
                  canCreateClaim: widget.canCreateClaim,
                  workspaceStyle: widget.workspaceStyle,
                ),
              ),
            ],
          );

          if (widget.workspaceStyle) {
            return ColoredBox(
              color: WorkspaceColors.background,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: Container(
                  decoration: workspaceCardDecoration(),
                  clipBehavior: Clip.antiAlias,
                  child: Column(
                    children: [
                      Container(
                        height: 54,
                        padding: const EdgeInsets.symmetric(horizontal: 18),
                        decoration: const BoxDecoration(
                          border: Border(
                            bottom: BorderSide(color: WorkspaceColors.border),
                          ),
                        ),
                        child: Row(
                          children: [
                            backButton(),
                            const SizedBox(width: 8),
                            Container(
                              width: 30,
                              height: 30,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: WorkspaceColors.setupBackground,
                                borderRadius: BorderRadius.circular(9),
                              ),
                              child: const Icon(
                                Icons.chat_bubble_outline_rounded,
                                color: WorkspaceColors.primary,
                                size: 18,
                              ),
                            ),
                            const SizedBox(width: 10),
                            const Text(
                              'Чат',
                              style: TextStyle(
                                color: WorkspaceColors.foreground,
                                fontSize: 16,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Align(
                                alignment: Alignment.centerLeft,
                                child: Container(
                                  constraints:
                                      const BoxConstraints(maxWidth: 360),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 9,
                                    vertical: 4,
                                  ),
                                  decoration: BoxDecoration(
                                    color: WorkspaceColors.secondaryBackground,
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: Text(
                                    widget.roomId,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: WorkspaceColors.mutedForeground,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w400,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            if (widget.isLead) leadMenu(),
                          ],
                        ),
                      ),
                      Expanded(child: messagesAndInput),
                    ],
                  ),
                ),
              ),
            );
          }

          return Scaffold(
            appBar: AppBar(
              toolbarHeight: isTablet ? 48 : null,
              leading: Center(child: backButton()),
              title: Text('Чат • ${widget.roomId}'),
              actions: [if (widget.isLead) leadMenu()],
            ),
            body: messagesAndInput,
          );
        },
      ),
    );
  }
}
