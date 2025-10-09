import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import 'chat_message.dart';

/// Провайдер чата для Supabase.
/// Таблица: public.chat_messages
/// Хранилище: bucket 'chat'
class ChatProvider with ChangeNotifier {
  final SupabaseClient _sb = Supabase.instance.client;
final _uuid = const Uuid();

  // roomId -> messages
  final Map<String, List<ChatMessage>> _byRoom = {};
  // roomId -> subscription
  final Map<String, dynamic> _subs = {};
  // senderId -> full name кеш
  final Map<String, String> _namesCache = {};

  List<ChatMessage> messages(String roomId) =>
      List.unmodifiable(_byRoom[roomId] ?? const []);

  bool isSubscribed(String roomId) => _subs.containsKey(roomId);

  
/// Реал-тайм подписка
Future<void> subscribe(String roomId) async {
  if (_subs.containsKey(roomId)) return;

  // 1) Первичная загрузка истории
  try {
    final rows = await _sb
        .from('chat_messages')
        .select('*')
        .eq('room_id', roomId)
        .order('created_at');

    var list = <ChatMessage>[];
    if (rows is List) {
      list = rows.map((row) => ChatMessage.fromMap(Map<String, dynamic>.from(row))).toList()
        ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    }
    _byRoom[roomId] = list;
    notifyListeners();

    // Подтягиваем имена, которых нет
    final missing = <String>{};
    for (final m in list) {
      final sid = (m.senderId ?? '').trim();
      final hasName = (m.senderName ?? '').trim().isNotEmpty;
      if (sid.isNotEmpty && !hasName && !_namesCache.containsKey(sid)) {
        missing.add(sid);
      }
    }
    if (missing.isNotEmpty) {
      final res = await _sb
          .from('documents')
          .select('id, data')
          .filter('collection', 'eq', 'employees')
          .inFilter('id', missing.toList());
      if (res is List) {
        for (final row in res) {
          final data = Map<String, dynamic>.from(row['data'] ?? {});
          final id = (row['id'] ?? '').toString();
          final last = (data['lastName'] ?? '').toString();
          final first = (data['firstName'] ?? '').toString();
          final patr = (data['patronymic'] ?? '').toString();
          _namesCache[id] = _fullName(last, first, patr);
        }
      }
    }
  } catch (_) {}

  // 2) Realtime подписка на изменения в documents
  final channel = _sb.channel('realtime:public:chat_messages');

  channel.onPostgresChanges(
    event: PostgresChangeEvent.all,
    schema: 'public',
    table: 'chat_messages',
    callback: (payload) {
      try {
        final recNew = Map<String, dynamic>.from(payload.newRecord ?? {});
        final recOld = Map<String, dynamic>.from(payload.oldRecord ?? {});

        final rid = (recNew['room_id'] ?? recOld['room_id'] ?? '').toString();
        if (rid != roomId) return;

        final id = (recNew['id'] ?? recOld['id'] ?? '').toString();
        final list = List<ChatMessage>.from(_byRoom[roomId] ?? const <ChatMessage>[]);

        if (recNew.isNotEmpty && (payload.oldRecord == null || recOld.isEmpty)) {
          // INSERT
          final msg = ChatMessage.fromMap(recNew);
          list.add(msg);
          list.sort((a, b) => a.createdAt.compareTo(b.createdAt));
          _byRoom[roomId] = list;
          notifyListeners();
        } else if (recNew.isNotEmpty && recOld.isNotEmpty) {
          // UPDATE
          final msg = ChatMessage.fromMap(recNew);
          final idx = list.indexWhere((m) => (m.id ?? '') == id);
          if (idx >= 0) {
            list[idx] = msg;
          } else {
            list.add(msg);
          }
          list.sort((a, b) => a.createdAt.compareTo(b.createdAt));
          _byRoom[roomId] = list;
          notifyListeners();
        } else if (recNew.isEmpty && recOld.isNotEmpty) {
          // DELETE
          list.removeWhere((m) => (m.id ?? '') == id);
          _byRoom[roomId] = list;
          notifyListeners();
        }
      } catch (_) {}
    },
  );

  await channel.subscribe();
  _subs[roomId] = channel;
}

Future<void> unsubscribe(String roomId) async {
  final sub = _subs.remove(roomId);
  if (sub is RealtimeChannel) {
    await sub.unsubscribe();
  } else if (sub is StreamSubscription) {
    await sub.cancel();
  }
}

/// Текст
    /// Текст
  Future<void> sendText({
    required String roomId,
    required String? senderId,
    required String? senderName,
    required String text,
  }) async {
    final id = _uuid.v4();
    await _sb.from('chat_messages').insert({
      'id': id,
      'room_id': roomId,
      'sender_id': senderId,
      'sender_name': (senderName ?? '').trim().isEmpty ? 'Сотрудник' : senderName,
      'kind': 'text',
      'body': text.trim(),
      'created_at': DateTime.now().toIso8601String(),
    });
  }

  /// Файл/медиа
    /// Файл/медиа
  Future<void> sendFile({
    required String roomId,
    required String? senderId,
    required String? senderName,
    required Uint8List bytes,
    required String filename,
    required String mime,
    String kind = 'file', // image | video | audio | file
    int? durationMs,
    int? width,
    int? height,
  }) async {
    final id = _uuid.v4();
    final ext = p.extension(filename).replaceAll('.', '');
    final path = '$roomId/$id.$ext';

    final storage = _sb.storage.from('chat');
    await storage.uploadBinary(
      path,
      bytes,
      fileOptions: FileOptions(contentType: mime, upsert: true),
    );
    final publicUrl = storage.getPublicUrl(path);

    await _sb.from('chat_messages').insert({
      'id': id,
      'room_id': roomId,
      'sender_id': senderId,
      'sender_name': (senderName ?? '').trim().isEmpty ? 'Сотрудник' : senderName,
      'kind': kind,
      'file_url': publicUrl,
      'file_mime': mime,
      'duration_ms': durationMs,
      'width': width,
      'height': height,
      'created_at': DateTime.now().toIso8601String(),
    });
  }

  /// Полная очистка комнаты
  Future<void> clearRoom(String roomId) async {
    await _sb.from('chat_messages').delete().eq('room_id', roomId);
  }

  /// Удалить за период
  Future<void> deleteMessagesInRange({
    required String roomId,
    DateTime? from,
    DateTime? to,
  }) async {
    var q = _sb.from('chat_messages').delete().eq('room_id', roomId);
    if (from != null) q = q.gte('created_at', from.toIso8601String());
    if (to != null) q = q.lt('created_at', to.toIso8601String());
    await q;
  }

  @override
  void dispose() {
    for (final s in _subs.values) {
      if (s is StreamSubscription) {
        s.cancel();
      } else if (s is RealtimeChannel) {
        s.unsubscribe();
      }
    }
    _subs.clear();
    super.dispose();
  }

  String _fullName(String? last, String? first, String? patr) {
    return [last, first, patr]
        .where((s) => (s ?? '').trim().isNotEmpty)
        .map((s) => s!.trim())
        .join(' ');
  }
}
