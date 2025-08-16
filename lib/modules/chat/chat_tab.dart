import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:provider/provider.dart';

import '../personnel/employee_model.dart';
import '../personnel/personnel_provider.dart';

/// Виджет чата между сотрудниками.
///
/// Получает [currentUserId], чтобы идентифицировать отправителя сообщений.
/// Загружает сообщения из Firebase (узел `messages`) и обновляет UI в реальном
/// времени. Позволяет отправлять текстовые сообщения. Каждое сообщение
/// содержит текст, идентификатор отправителя и временную метку. Сообщения
/// отображаются в порядке отправки, причём сообщения текущего пользователя
/// выравниваются вправо, остальные — влево.
class ChatTab extends StatefulWidget {
  final String currentUserId;
  const ChatTab({super.key, required this.currentUserId});

  @override
  State<ChatTab> createState() => _ChatTabState();
}

class _ChatTabState extends State<ChatTab> {
  final SupabaseClient _supabase = Supabase.instance.client;
  final TextEditingController _controller = TextEditingController();
  List<_ChatMessage> _messages = [];

  @override
  void initState() {
    super.initState();
    _listenToMessages();
  }

  void _listenToMessages() {
    _supabase
        .from('messages')
        .stream(primaryKey: ['id'])
        .order('timestamp')
        .listen((rows) {
      final loaded = rows.map((row) {
        final map = Map<String, dynamic>.from(row as Map);
        return _ChatMessage(
          id: map['id'].toString(),
          senderId: map['senderId'] as String? ?? '',
          text: map['text'] as String? ?? '',
          timestamp: map['timestamp'] as int? ?? 0,
        );
      }).toList()
        ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
      setState(() {
        _messages = loaded;
      });
    });
  }

  Future<void> _sendMessage() async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    _controller.clear();
    await _supabase.from('messages').insert({
      'senderId': widget.currentUserId,
      'text': text,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    });
  }

  @override
  Widget build(BuildContext context) {
    final personnel = context.watch<PersonnelProvider>();
    return Column(
      children: [
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.all(8),
            itemCount: _messages.length,
            itemBuilder: (context, index) {
              final msg = _messages[index];
              final isMine = msg.senderId == widget.currentUserId;
              final employee = personnel.employees.firstWhere(
                (e) => e.id == msg.senderId,
                orElse: () => EmployeeModel(
                  id: '',
                  lastName: 'Неизвестно',
                  firstName: '',
                  patronymic: '',
                  iin: '',
                  positionIds: [],
                ),
              );
              final senderName = '${employee.firstName} ${employee.lastName}'.trim();
              return Align(
                alignment: isMine
                    ? Alignment.centerRight
                    : Alignment.centerLeft,
                child: Container(
                  margin: const EdgeInsets.symmetric(vertical: 4),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: isMine
                        ? Colors.blue.shade100
                        : Colors.grey.shade200,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    crossAxisAlignment: isMine
                        ? CrossAxisAlignment.end
                        : CrossAxisAlignment.start,
                    children: [
                      Text(
                        senderName,
                        style: const TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: Colors.black54,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(msg.text),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(8.0),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _controller,
                  decoration: const InputDecoration(
                    hintText: 'Введите сообщение...',
                    border: OutlineInputBorder(),
                  ),
                  minLines: 1,
                  maxLines: 3,
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                icon: const Icon(Icons.send),
                onPressed: _sendMessage,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Вспомогательный класс для сообщений чата.
class _ChatMessage {
  final String id;
  final String senderId;
  final String text;
  final int timestamp;
  _ChatMessage({
    required this.id,
    required this.senderId,
    required this.text,
    required this.timestamp,
  });
}