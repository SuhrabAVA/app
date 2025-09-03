import 'package:flutter/material.dart';

class ChatScreen extends StatelessWidget {
  const ChatScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Чат')),
      body: const Center(
        child: Text(
          'Здесь будет чат между сотрудниками',
          style: TextStyle(fontSize: 18),
        ),
      ),
    );
  }
}
