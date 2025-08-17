
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
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    // Подписываемся в addPostFrame, чтобы гарантированно был доступен Provider
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final chat = context.read<ChatProvider>();
      chat.subscribe(widget.roomId);
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    // НЕ обращаемся к Provider через context в dispose() (чтобы избежать "deactivated widget's ancestor")
    final chat = Provider.of<ChatProvider>(context, listen: false);
    chat.unsubscribe(widget.roomId);
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

  @override
  Widget build(BuildContext context) {
    return Consumer<ChatProvider>(
      builder: (context, chat, _) {
        final list = chat.messages(widget.roomId);
        // автопрокрутка вниз при новых сообщениях
        WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToEnd());

        return Scaffold(
          appBar: AppBar(
            title: Text('Чат • ${widget.roomId}'),
          ),
          body: Column(
            children: [
              Expanded(
                child: ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: list.length,
                  itemBuilder: (context, i) {
                    final m = list[i];
                    final isMine = m.senderId == widget.meId;
                    return MessageBubble(m: m, isMine: isMine);
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                child: ChatInputBar(
                  roomId: widget.roomId,
                  senderId: widget.meId,
                  senderName: widget.meName,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
