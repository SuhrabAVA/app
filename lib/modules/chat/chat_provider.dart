import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import 'chat_message.dart';
import 'chat_mention_candidate.dart';

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
  // предотвращаем дублирующиеся запросы за именами
  final Set<String> _pendingNames = {};
  // список сотрудников для подсказок @упоминаний
  final List<ChatMentionCandidate> _mentionCandidates = [];
  bool _mentionLoading = false;

  List<ChatMessage> messages(String roomId) =>
      List.unmodifiable(_byRoom[roomId] ?? const []);

  bool isSubscribed(String roomId) => _subs.containsKey(roomId);

  /// Возвращает список сотрудников для подсказок при вводе `@`.
  Future<List<ChatMentionCandidate>> mentionCandidates({String query = ''}) async {
    await _ensureMentionCandidates();
    final q = query.trim();
    final matches = _mentionCandidates
        .where((c) => c.matches(q))
        .toList(growable: false)
      ..sort((a, b) => a.displayName.compareTo(b.displayName));
    // ограничиваем до 8 элементов, чтобы не перегружать подсказку
    return matches.length > 8 ? matches.sublist(0, 8) : matches;
  }

  Future<void> _ensureMentionCandidates() async {
    if (_mentionCandidates.isNotEmpty || _mentionLoading) return;
    _mentionLoading = true;
    try {
      final res = await _sb
          .from('documents')
          .select('id, data')
          .eq('collection', 'employees');
      if (res is List) {
        _mentionCandidates
          ..clear()
          ..addAll(res.whereType<Map>().map((raw) {
            final row = Map<String, dynamic>.from(raw as Map);
            final id = (row['id'] ?? '').toString();
            final data = Map<String, dynamic>.from(row['data'] ?? {});
            final isFired = (data['isFired'] as bool?) ?? false;
            if (id.isEmpty || isFired) return null;
            final candidate = ChatMentionCandidate.fromEmployeeRow(id, data);
            if (candidate.displayName.trim().isEmpty) return null;
            return candidate;
          }).whereType<ChatMentionCandidate>());
      }
    } catch (_) {
      // игнорируем ошибки Supabase, подсказки просто не появятся
    } finally {
      _mentionLoading = false;
    }
  }

  
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
        list = rows
            .map((row) => ChatMessage.fromMap(Map<String, dynamic>.from(row)))
            .toList()
          ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
      }
      list = _applyNames(list);
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
        final fetched = await _fetchNamesBatch(missing);
        if (fetched.isNotEmpty) {
          final current = List<ChatMessage>.from(_byRoom[roomId] ?? const <ChatMessage>[]);
          final updated = _applyNames(current, extra: fetched);
          _byRoom[roomId] = updated;
          notifyListeners();
        }
      }
    } catch (_) {}

    // 2) Realtime подписка на изменения
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
            final msg = _withSenderName(ChatMessage.fromMap(recNew));
            list.add(msg);
            list.sort((a, b) => a.createdAt.compareTo(b.createdAt));
            _byRoom[roomId] = _applyNames(list);
            notifyListeners();
          } else if (recNew.isNotEmpty && recOld.isNotEmpty) {
            // UPDATE
            final msg = _withSenderName(ChatMessage.fromMap(recNew));
            final idx = list.indexWhere((m) => m.id == id);
            if (idx >= 0) {
              list[idx] = msg;
            } else {
              list.add(msg);
            }
            list.sort((a, b) => a.createdAt.compareTo(b.createdAt));
            _byRoom[roomId] = _applyNames(list);
            notifyListeners();
          } else if (recNew.isEmpty && recOld.isNotEmpty) {
            // DELETE
            list.removeWhere((m) => m.id == id);
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
  Future<void> sendText({
    required String roomId,
    required String? senderId,
    required String? senderName,
    required String text,
  }) async {
    final id = _uuid.v4();
    final preparedName = _prepareSenderName(senderId, senderName);
    final normalizedSenderId = (senderId ?? '').trim();
    if (preparedName != null && preparedName.isNotEmpty && normalizedSenderId.isNotEmpty) {
      _namesCache[normalizedSenderId] = preparedName;
    }
    await _sb.from('chat_messages').insert({
      'id': id,
      'room_id': roomId,
      'sender_id': senderId,
      'sender_name': preparedName,
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

    final preparedName = _prepareSenderName(senderId, senderName);
    final normalizedSenderId = (senderId ?? '').trim();
    if (preparedName != null && preparedName.isNotEmpty && normalizedSenderId.isNotEmpty) {
      _namesCache[normalizedSenderId] = preparedName;
    }

    await _sb.from('chat_messages').insert({
      'id': id,
      'room_id': roomId,
      'sender_id': senderId,
      'sender_name': preparedName,
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

  String? _prepareSenderName(String? senderId, String? senderName) {
    final provided = (senderName ?? '').trim();
    if (provided.isNotEmpty) return provided;

    final id = (senderId ?? '').trim();
    if (id.isEmpty) return null;

    final cached = (_namesCache[id] ?? '').trim();
    if (cached.isNotEmpty) return cached;

    unawaited(_fetchAndCacheName(id));
    return null;
  }

  List<ChatMessage> _applyNames(List<ChatMessage> source, {Map<String, String>? extra}) {
    if (source.isEmpty) return source;
    var changed = false;
    final result = <ChatMessage>[];
    for (final msg in source) {
      final withName = _withSenderName(msg, extra: extra);
      if (!identical(withName, msg)) changed = true;
      result.add(withName);
    }
    return changed ? result : source;
  }

  ChatMessage _withSenderName(ChatMessage msg, {Map<String, String>? extra}) {
    final current = (msg.senderName ?? '').trim();
    final id = (msg.senderId ?? '').trim();

    if (id.isNotEmpty) {
      final candidate = ((extra?[id] ?? _namesCache[id]) ?? '').trim();
      if (candidate.isNotEmpty && candidate != current) {
        _namesCache[id] = candidate;
        return msg.copyWith(senderName: candidate);
      }
    }

    if (current.isNotEmpty) {
      return current == msg.senderName ? msg : msg.copyWith(senderName: current);
    }

    if (id.isEmpty) return msg;

    unawaited(_fetchAndCacheName(id));
    return msg;
  }

  Future<Map<String, String>> _fetchNamesBatch(Set<String> ids) async {
    final result = <String, String>{};
    if (ids.isEmpty) return result;
    try {
      final res = await _sb
          .from('documents')
          .select('id, data')
          .filter('collection', 'eq', 'employees')
          .inFilter('id', ids.toList());
      if (res is List) {
        for (final raw in res) {
          if (raw is! Map) continue;
          final row = Map<String, dynamic>.from(raw as Map);
          final id = (row['id'] ?? '').toString();
          final data = Map<String, dynamic>.from(row['data'] ?? {});
          final last = (data['lastName'] ?? '').toString();
          final first = (data['firstName'] ?? '').toString();
          final patr = (data['patronymic'] ?? '').toString();
          final name = _fullName(last, first, patr);
          if (id.isNotEmpty && name.isNotEmpty) {
            result[id] = name;
            _namesCache[id] = name;
          }
        }
      }
    } catch (_) {}
    return result;
  }

  Future<void> _fetchAndCacheName(String senderId) async {
    if (senderId.isEmpty || _namesCache.containsKey(senderId) || _pendingNames.contains(senderId)) {
      return;
    }
    _pendingNames.add(senderId);
    try {
      final dynamic res = await _sb
          .from('documents')
          .select('id, data')
          .filter('collection', 'eq', 'employees')
          .eq('id', senderId)
          .limit(1);

      Map<String, dynamic>? row;
      if (res is Map<String, dynamic>) {
        row = res;
      } else if (res is List && res.isNotEmpty) {
        final first = res.first;
        if (first is Map<String, dynamic>) {
          row = first;
        } else if (first is Map) {
          row = Map<String, dynamic>.from(first as Map);
        }
      }

      if (row != null) {
        final data = Map<String, dynamic>.from(row['data'] ?? {});
        final last = (data['lastName'] ?? '').toString();
        final first = (data['firstName'] ?? '').toString();
        final patr = (data['patronymic'] ?? '').toString();
        final name = _fullName(last, first, patr);
        if (name.isNotEmpty) {
          _namesCache[senderId] = name;
          var updatedAny = false;
          for (final entry in _byRoom.entries.toList()) {
            final list = entry.value;
            var roomChanged = false;
            final updated = <ChatMessage>[];
            for (final msg in list) {
              if ((msg.senderId ?? '').trim() == senderId) {
                if ((msg.senderName ?? '').trim() != name) {
                  updated.add(msg.copyWith(senderName: name));
                  roomChanged = true;
                } else {
                  updated.add(msg);
                }
              } else {
                updated.add(msg);
              }
            }
            if (roomChanged) {
              _byRoom[entry.key] = updated;
              updatedAny = true;
            }
          }
          if (updatedAny) notifyListeners();
        }
      }
    } catch (_) {} finally {
      _pendingNames.remove(senderId);
    }
  }

  String _fullName(String? last, String? first, String? patr) {
    return [last, first, patr]
        .where((s) => (s ?? '').trim().isNotEmpty)
        .map((s) => s!.trim())
        .join(' ');
  }
}
