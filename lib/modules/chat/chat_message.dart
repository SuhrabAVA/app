
import 'package:flutter/foundation.dart';

/// Модель сообщения в чате
/// Поддерживаемые типы: text, image, video, audio, file
@immutable
class ChatMessage {
  final String id;
  final String roomId;
  final String? senderId;
  final String? senderName; // <-- имя сотрудника
  final String kind; // 'text' | 'image' | 'video' | 'audio' | 'file'
  final String? body; // текстовое содержимое, подпись к файлу
  final String? fileUrl; // ссылка на файл (фото/видео/аудио/файл)
  final String? fileMime;
  final int? durationMs; // для аудио/видео
  final int? width; // для изображений
  final int? height; // для изображений
  final DateTime createdAt;

  const ChatMessage({
    required this.id,
    required this.roomId,
    required this.senderId,
    required this.senderName,
    required this.kind,
    required this.createdAt,
    this.body,
    this.fileUrl,
    this.fileMime,
    this.durationMs,
    this.width,
    this.height,
  });

  ChatMessage copyWith({
    String? id,
    String? roomId,
    String? senderId,
    String? senderName,
    String? kind,
    String? body,
    String? fileUrl,
    String? fileMime,
    int? durationMs,
    int? width,
    int? height,
    DateTime? createdAt,
  }) {
    return ChatMessage(
      id: id ?? this.id,
      roomId: roomId ?? this.roomId,
      senderId: senderId ?? this.senderId,
      senderName: senderName ?? this.senderName,
      kind: kind ?? this.kind,
      body: body ?? this.body,
      fileUrl: fileUrl ?? this.fileUrl,
      fileMime: fileMime ?? this.fileMime,
      durationMs: durationMs ?? this.durationMs,
      width: width ?? this.width,
      height: height ?? this.height,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  Map<String, dynamic> toMap() => {
        'id': id,
        'room_id': roomId,
        'sender_id': senderId,
        'sender_name': senderName,
        'kind': kind,
        'body': body,
        'file_url': fileUrl,
        'file_mime': fileMime,
        'duration_ms': durationMs,
        'width': width,
        'height': height,
        'created_at': createdAt.toIso8601String(),
      };

  factory ChatMessage.fromMap(Map<String, dynamic> m) {
    return ChatMessage(
      id: m['id'] as String,
      roomId: m['room_id'] as String,
      senderId: m['sender_id'] as String?,
      senderName: m['sender_name'] as String?,
      kind: m['kind'] as String,
      body: m['body'] as String?,
      fileUrl: m['file_url'] as String?,
      fileMime: m['file_mime'] as String?,
      durationMs: m['duration_ms'] as int?,
      width: m['width'] as int?,
      height: m['height'] as int?,
      createdAt: DateTime.tryParse('${m['created_at']}') ?? DateTime.now(),
    );
  }
}
