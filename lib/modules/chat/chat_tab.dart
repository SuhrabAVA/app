import 'package:flutter/material.dart';

class ChatTab extends StatelessWidget {
  const ChatTab({super.key});

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Text(
        'Здесь будет чат между сотрудниками',
        style: TextStyle(fontSize: 18),
      ),
    );
  }
}
