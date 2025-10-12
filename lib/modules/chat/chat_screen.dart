import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'chat_message.dart';
import 'chat_provider.dart';
import 'widgets/message_bubble.dart';
import 'widgets/input_bar.dart';

class ChatScreen extends StatefulWidget {
  final String roomId;
  final String meId;
  final String? meName;
  final bool isLead; // техлид?

  const ChatScreen({
    super.key,
    required this.roomId,
    required this.meId,
    this.meName,
    this.isLead = false,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  late ChatProvider _chat;
  bool _chatReady = false;
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    // Подписываемся в addPostFrame, чтобы гарантированно был доступен Provider
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_chatReady) {
        _chat.subscribe(widget.roomId);
      }
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
    if (!_scroll.hasClients) return;
    _scroll.animateTo(
      _scroll.position.maxScrollExtent,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
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
    return Consumer<ChatProvider>(
      builder: (context, chat, _) {
        final list = chat.messages(widget.roomId);
        // автопрокрутка вниз при новых сообщениях
        WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToEnd());

        final media = MediaQuery.of(context);
        final bool isTablet = media.size.shortestSide >= 600 && media.size.shortestSide < 1100;
        final double scale = isTablet ? 0.9 : 1.0;
        double scaled(double value) => value * scale;

        return Scaffold(
          appBar: AppBar(
            toolbarHeight: isTablet ? 48 : null,
            title: Text('Чат • ${widget.roomId}'),
            actions: [
              if (widget.isLead)
                PopupMenuButton<String>(
                  onSelected: _handleMenu,
                  itemBuilder: (ctx) => const [
                    PopupMenuItem(value: 'clear', child: Text('Очистить чат')),
                    PopupMenuItem(
                        value: 'range', child: Text('Удалить за период')),
                  ],
                ),
            ],
          ),
          body: Column(
            children: [
              Expanded(
                child: ListView.builder(
                  controller: _scroll,
                  padding: EdgeInsets.symmetric(vertical: scaled(6)),
                  itemCount: list.length,
                  itemBuilder: (context, i) {
                    final m = list[i];
                    final isMine = m.senderId == widget.meId;
                    return MessageBubble(m: m, isMine: isMine);
                  },
                ),
              ),
              Padding(
                padding: EdgeInsets.fromLTRB(scaled(8), 0, scaled(8), scaled(8)),
                child: ChatInputBar(
                  roomId: widget.roomId,
                  senderId: widget.meId,
                  senderName: widget.meName,
                  scale: scale,
                  compact: isTablet,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
