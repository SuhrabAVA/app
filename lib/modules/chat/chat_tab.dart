
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'chat_screen.dart';    
import 'chat_provider.dart';


class ChatTab extends StatelessWidget {
  final String currentUserId;
  final String? currentUserName;
  final String roomId;
  final bool isLead;

  const ChatTab({
    super.key,
    required this.currentUserId,
    this.currentUserName,
    this.roomId = 'general',
    this.isLead = false,
  });

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => ChatProvider(),
      child: ChatScreen(
        roomId: roomId,
        meId: currentUserId,
        meName: currentUserName,
        isLead: isLead,
      ),
    );
  }
}
