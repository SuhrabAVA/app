import 'package:flutter/material.dart';

import 'chat_tab.dart';

/// Отдельный экран чата, который можно открыть из навигации приложения.
///
/// Для использования необходимо передать идентификатор текущего пользователя
/// через аргумент [currentUserId]. Если идентификатор не указан, экран
/// отображает пустой контейнер.
class ChatScreen extends StatelessWidget {
  final String currentUserId;
  const ChatScreen({super.key, required this.currentUserId});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Чат')),
      body: currentUserId.isEmpty
          ? const Center(child: Text('Не указан пользователь'))
          : ChatTab(currentUserId: currentUserId),
    );
  }
}