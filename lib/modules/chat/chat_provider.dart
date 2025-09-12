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
  final Map<String, StreamSubscription<List<Map<String, dynamic>>>> _subs = {};
  // senderId -> full name кеш
  final Map<String, String> _namesCache = {};

  List<ChatMessage> messages(String roomId) =>
      List.unmodifiable(_byRoom[roomId] ?? const []);

  bool isSubscribed(String roomId) => _subs.containsKey(roomId);

  /// Реал-тайм подписка
  Future<void> subscribe(String roomId) async {
    if (_subs.containsKey(roomId)) return;

    final stream = _sb
        .from('chat_messages')
        .stream(primaryKey: ['id'])
        .eq('room_id', roomId)
        .order('created_at');

    final sub = stream.listen((rows) async {
      // Базовый список
      var list = rows.map(ChatMessage.fromMap).toList()
        ..sort((a, b) => a.createdAt.compareTo(b.createdAt));

      // Собираем id отправителей с пустым именем и которых ещё нет в кешe
      final missing = <String>{};
      for (final m in list) {
        final sid = (m.senderId ?? '').trim();
        final hasName = (m.senderName ?? '').trim().isNotEmpty;
        if (sid.isNotEmpty && !hasName && !_namesCache.containsKey(sid)) {
          missing.add(sid);
        }
      }

      // Подтягиваем имена из employees одним запросом
      if (missing.isNotEmpty) {
        try {
          final res = await _sb
              .from('employees')
              .select('id, firstName, lastName, patronymic')
              .inFilter('id', missing.toList());
          if (res is List) {
            for (final row in res) {
              final r = Map<String, dynamic>.from(row);
              final id = (r['id'] ?? '').toString();
              final full = _fullName(
                r['lastName']?.toString(),
                r['firstName']?.toString(),
                r['patronymic']?.toString(),
              );
              if (id.isNotEmpty && full.isNotEmpty) {
                _namesCache[id] = full;
              }
            }
          }
        } catch (_) {/* тихо */}
      }

      // Обогащаем сообщения именем из кеша
      list = list
          .map((m) => ((m.senderName ?? '').trim().isEmpty &&
                  (m.senderId ?? '').isNotEmpty &&
                  _namesCache[(m.senderId ?? '')] != null)
              ? m.copyWith(senderName: _namesCache[(m.senderId ?? '')])
              : m)
          .toList();

      _byRoom[roomId] = list;
      notifyListeners();
    });

    _subs[roomId] = sub;
  }

  Future<void> unsubscribe(String roomId) async {
    final s = _subs.remove(roomId);
    await s?.cancel();
  }

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
      s.cancel();
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
