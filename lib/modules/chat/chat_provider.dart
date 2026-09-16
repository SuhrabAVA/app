import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import 'chat_message.dart';
import 'chat_mention_candidate.dart';
import '../../services/realtime_sync_service.dart';
import '../../utils/auth_helper.dart';

/// Провайдер чата для Supabase.
/// Таблица: public.chat_messages
/// Хранилище: bucket 'chat'
class ChatProvider with ChangeNotifier {
  ChatProvider() {
    RealtimeSyncService.instance.registerRefreshHandler(
      owner: this,
      resource: RealtimeResource.chat,
      handler: _refreshActiveChatData,
    );
    AuthHelper.sessionRevision.addListener(_onLogicalSessionChanged);
  }

  // late: инициализатор поля дёргает Supabase.instance прямо в конструкторе и
  // роняет ассертом любой виджет-тест, который просто строит экран чата.
  late final SupabaseClient _sb = Supabase.instance.client;
  final _uuid = const Uuid();

  // roomId -> messages
  final Map<String, List<ChatMessage>> _byRoom = {};
  // roomId -> subscription
  final Map<String, dynamic> _subs = {};
  final Set<String> _subscribingRooms = <String>{};
  final Set<String> _desiredRooms = <String>{};
  final Map<String, int> _roomGenerations = <String, int>{};
  final Map<String, String> _roomStatuses = <String, String>{};
  final Map<String, Completer<void>> _subscriptionWaiters = {};
  final Map<String, RealtimeRefreshScheduler> _roomRefreshSchedulers = {};
  final Map<String, Timer> _roomReconnectTimers = {};
  final Map<String, int> _roomReconnectAttempts = {};
  // senderId -> full name кеш
  final Map<String, String> _namesCache = {};
  // предотвращаем дублирующиеся запросы за именами
  final Set<String> _pendingNames = {};
  // список сотрудников для подсказок @упоминаний
  final List<ChatMentionCandidate> _mentionCandidates = [];
  bool _mentionLoading = false;
  bool _disposed = false;

  List<ChatMessage> messages(String roomId) =>
      List.unmodifiable(_byRoom[roomId] ?? const []);

  bool isSubscribed(String roomId) => _subs.containsKey(roomId);

  void debugDumpDiagnostics() {
    if (!kDebugMode) return;
    debugPrint(
      '[REALTIME] chat diagnostics channels=${_subs.length} '
      'subscribing=${_subscribingRooms.length} desired=${_desiredRooms.length} '
      'refreshTimers=${_roomRefreshSchedulers.values.where((s) => s.isScheduled).length} '
      'refreshRunning=${_roomRefreshSchedulers.values.where((s) => s.isRefreshing).length} '
      'reconnectTimers=${_roomReconnectTimers.length} '
      'rooms=${_subs.keys.toList(growable: false)} statuses=$_roomStatuses',
    );
  }

  Future<void> _refreshActiveChatData() async {
    _mentionCandidates.clear();
    _namesCache.clear();
    await Future.wait(
      _subs.keys.toList(growable: false).map(
            (roomId) => _refreshRoom(
              roomId,
              generation: _roomGenerations[roomId] ?? 0,
            ),
          ),
    );
  }

  void _onLogicalSessionChanged() {
    if (AuthHelper.currentUserId == null) {
      _byRoom.clear();
      _mentionCandidates.clear();
      _namesCache.clear();
      _pendingNames.clear();
      notifyListeners();
      unawaited(_unsubscribeAll());
    }
  }

  /// Возвращает список сотрудников для подсказок при вводе `@`.
  Future<List<ChatMentionCandidate>> mentionCandidates(
      {String query = ''}) async {
    await _ensureMentionCandidates();
    final q = query.trim();
    final matches = _mentionCandidates
        .where((c) => c.matches(q))
        .toList(growable: false)
      ..sort((a, b) => a.displayName.compareTo(b.displayName));
    // ограничиваем до 8 элементов, чтобы не перегружать подсказку
    return matches.length > 8 ? matches.sublist(0, 8) : matches;
  }

  /// Полный список сотрудников для выбора адресатов претензии
  /// (без ограничения в 8 элементов, как у подсказок упоминаний).
  Future<List<ChatMentionCandidate>> claimCandidates(
      {String query = ''}) async {
    await _ensureMentionCandidates();
    final q = query.trim();
    return _mentionCandidates.where((c) => c.matches(q)).toList(growable: false)
      ..sort((a, b) => a.displayName.compareTo(b.displayName));
  }

  Future<void> _ensureMentionCandidates() async {
    if (_mentionCandidates.isNotEmpty || _mentionLoading) return;
    final sessionRevision = AuthHelper.sessionRevision.value;
    _mentionLoading = true;
    try {
      // Источник — тот же employees_view, что и PersonnelProvider/аналитика
      // (единый id сотрудника: раньше читали давно неактуальную коллекцию
      // documents/collection=employees, которая пуста в проде).
      final res = await _sb
          .from('employees_view')
          .select('id, last_name, first_name, patronymic, is_fired');
      if (_disposed || sessionRevision != AuthHelper.sessionRevision.value) {
        return;
      }
      if (res is List) {
        _mentionCandidates
          ..clear()
          ..addAll(res.whereType<Map>().map((raw) {
            final row = Map<String, dynamic>.from(raw as Map);
            final id = (row['id'] ?? '').toString();
            final isFired = (row['is_fired'] as bool?) ?? false;
            if (id.isEmpty || isFired) return null;
            final candidate = ChatMentionCandidate.fromEmployeeRow(id, row);
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
    if (_disposed || _subs.containsKey(roomId)) return;
    _desiredRooms.add(roomId);
    final generation = (_roomGenerations[roomId] ?? 0) + 1;
    _roomGenerations[roomId] = generation;
    if (!_subscribingRooms.add(roomId)) return;

    RealtimeChannel? channel;
    try {
      // INSERT/UPDATE фильтруются на сервере по открытой комнате. DELETE
      // слушается без фильтра: Postgres не гарантирует наличие room_id в
      // oldRecord без REPLICA IDENTITY FULL, поэтому просто перечитываем
      // единственную открытую комнату.
      final filter = PostgresChangeFilter(
        type: PostgresChangeFilterType.eq,
        column: 'room_id',
        value: roomId,
      );
      channel = _sb.channel('chat:$roomId:$generation');
      channel
          .onPostgresChanges(
            event: PostgresChangeEvent.insert,
            schema: 'public',
            table: 'chat_messages',
            filter: filter,
            callback: (_) => _scheduleRoomRefresh(roomId),
          )
          .onPostgresChanges(
            event: PostgresChangeEvent.update,
            schema: 'public',
            table: 'chat_messages',
            filter: filter,
            callback: (_) => _scheduleRoomRefresh(roomId),
          )
          .onPostgresChanges(
            event: PostgresChangeEvent.delete,
            schema: 'public',
            table: 'chat_messages',
            callback: (_) => _scheduleRoomRefresh(roomId),
          );

      final subscribed = Completer<void>();
      _subscriptionWaiters[roomId] = subscribed;
      final activeChannel = channel;
      _subs[roomId] = activeChannel;
      activeChannel.subscribe((status, error) {
        if (!_isCurrentRoomGeneration(roomId, generation) ||
            !identical(_subs[roomId], activeChannel)) {
          if (!subscribed.isCompleted) subscribed.complete();
          return;
        }
        final statusName = status.name;
        _roomStatuses[roomId] = statusName;
        if (statusName == 'subscribed') {
          _roomReconnectTimers.remove(roomId)?.cancel();
          _roomReconnectAttempts.remove(roomId);
          if (!subscribed.isCompleted) subscribed.complete();
          return;
        }
        if (statusName == 'closed' ||
            statusName == 'channelError' ||
            statusName == 'timedOut') {
          if (!subscribed.isCompleted) {
            subscribed.completeError(
              error ?? StateError('Chat subscription $statusName'),
            );
          } else {
            unawaited(
              _handleRoomDisconnect(roomId, generation, activeChannel),
            );
          }
        }
      });
      await subscribed.future.timeout(const Duration(seconds: 15));
      if (!_isCurrentRoomGeneration(roomId, generation)) {
        await _sb.removeChannel(activeChannel);
        return;
      }

      // SELECT после SUBSCRIBED закрывает окно потери сообщения между
      // первичной загрузкой истории и включением подписки.
      await _refreshRoom(roomId, generation: generation);
      debugDumpDiagnostics();
    } catch (_) {
      if (channel != null && identical(_subs[roomId], channel)) {
        _subs.remove(roomId);
        _roomStatuses.remove(roomId);
        await _sb.removeChannel(channel);
      }
      if (_isCurrentRoomGeneration(roomId, generation)) {
        _scheduleRoomReconnect(roomId, generation);
      }
      rethrow;
    } finally {
      _subscriptionWaiters.remove(roomId);
      _subscribingRooms.remove(roomId);
      if (!_disposed &&
          _desiredRooms.contains(roomId) &&
          !_subs.containsKey(roomId) &&
          _roomGenerations[roomId] != generation) {
        unawaited(subscribe(roomId));
      }
    }
  }

  Future<void> _handleRoomDisconnect(
    String roomId,
    int generation,
    RealtimeChannel channel,
  ) async {
    if (!_isCurrentRoomGeneration(roomId, generation) ||
        !identical(_subs[roomId], channel)) {
      return;
    }
    _subs.remove(roomId);
    _roomStatuses.remove(roomId);
    await _sb.removeChannel(channel);
    if (_isCurrentRoomGeneration(roomId, generation)) {
      _scheduleRoomReconnect(roomId, generation);
    }
  }

  void _scheduleRoomReconnect(String roomId, int generation) {
    if (!_isCurrentRoomGeneration(roomId, generation) ||
        _roomReconnectTimers.containsKey(roomId)) {
      return;
    }
    final attempt = (_roomReconnectAttempts[roomId] ?? 0) + 1;
    _roomReconnectAttempts[roomId] = attempt;
    final seconds = 1 << (attempt - 1).clamp(0, 5);
    _roomReconnectTimers[roomId] = Timer(Duration(seconds: seconds), () async {
      _roomReconnectTimers.remove(roomId);
      if (!_isCurrentRoomGeneration(roomId, generation) ||
          _subs.containsKey(roomId)) {
        return;
      }
      try {
        await subscribe(roomId);
      } catch (error) {
        if (kDebugMode) {
          debugPrint(
            '[REALTIME] chat reconnect failed room=$roomId error=$error',
          );
        }
        final currentGeneration = _roomGenerations[roomId];
        if (currentGeneration != null) {
          _scheduleRoomReconnect(roomId, currentGeneration);
        }
      }
    });
  }

  bool _isCurrentRoomGeneration(String roomId, int generation) =>
      !_disposed &&
      _desiredRooms.contains(roomId) &&
      _roomGenerations[roomId] == generation;

  Future<void> _refreshRoom(
    String roomId, {
    required int generation,
  }) async {
    try {
      final rows = await _sb
          .from('chat_messages')
          .select('*')
          .eq('room_id', roomId)
          .order('created_at');
      if (!_isCurrentRoomGeneration(roomId, generation)) return;
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

      final missing = <String>{};
      for (final message in list) {
        final senderId = (message.senderId ?? '').trim();
        final hasName = (message.senderName ?? '').trim().isNotEmpty;
        if (senderId.isNotEmpty &&
            !hasName &&
            !_namesCache.containsKey(senderId)) {
          missing.add(senderId);
        }
      }
      if (missing.isEmpty) return;
      final fetched = await _fetchNamesBatch(missing);
      if (!_isCurrentRoomGeneration(roomId, generation)) return;
      if (fetched.isEmpty) return;
      final current = List<ChatMessage>.from(
        _byRoom[roomId] ?? const <ChatMessage>[],
      );
      _byRoom[roomId] = _applyNames(current, extra: fetched);
      notifyListeners();
    } catch (error) {
      if (kDebugMode) {
        debugPrint('[REALTIME] chat refresh failed room=$roomId error=$error');
      }
    }
  }

  void _scheduleRoomRefresh(String roomId) {
    if (_disposed || !_desiredRooms.contains(roomId)) return;
    _roomRefreshSchedulers
        .putIfAbsent(
          roomId,
          () => RealtimeRefreshScheduler(
            debounce: const Duration(milliseconds: 200),
            handler: () => _refreshRoom(
              roomId,
              generation: _roomGenerations[roomId] ?? 0,
            ),
            onCoalesced: () {
              if (kDebugMode) {
                debugPrint('[REALTIME] chat refresh coalesced room=$roomId');
              }
            },
          ),
        )
        .schedule();
  }

  Future<void> unsubscribe(String roomId) async {
    _desiredRooms.remove(roomId);
    _roomGenerations[roomId] = (_roomGenerations[roomId] ?? 0) + 1;
    _roomRefreshSchedulers.remove(roomId)?.dispose();
    _roomReconnectTimers.remove(roomId)?.cancel();
    _roomReconnectAttempts.remove(roomId);
    final waiter = _subscriptionWaiters.remove(roomId);
    if (waiter != null && !waiter.isCompleted) waiter.complete();
    final sub = _subs.remove(roomId);
    _roomStatuses.remove(roomId);
    if (sub is RealtimeChannel) {
      await _sb.removeChannel(sub);
    } else if (sub is StreamSubscription) {
      await sub.cancel();
    }
    debugDumpDiagnostics();
  }

  Future<void> _unsubscribeAll() async {
    final rooms = <String>{..._desiredRooms, ..._subs.keys};
    await Future.wait(rooms.map(unsubscribe));
  }

  /// Текст
  Future<void> sendText({
    required String roomId,
    required String? senderId,
    required String? senderName,
    required String text,
    String? messageId,
    List<ChatClaimTarget> claimTargets = const [],
  }) async {
    // id может прийти извне: претензии ссылаются на сообщение по message_id
    // и создаются ДО его вставки.
    final id = (messageId ?? '').trim().isNotEmpty ? messageId!.trim() : _uuid.v4();
    final preparedName = _prepareSenderName(senderId, senderName);
    final normalizedSenderId = (senderId ?? '').trim();
    if (preparedName != null &&
        preparedName.isNotEmpty &&
        normalizedSenderId.isNotEmpty) {
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
      if (claimTargets.isNotEmpty)
        'claim_targets': [for (final t in claimTargets) t.toMap()],
    });
  }

  /// Новый id сообщения: генерируется клиентом заранее, чтобы претензии
  /// могли ссылаться на сообщение ещё до его вставки.
  String newMessageId() => _uuid.v4();

  /// Путь файла в bucket 'chat' — единственное место, где он строится.
  static String mediaPath(String roomId, String messageId, String filename) {
    final ext = p.extension(filename).replaceAll('.', '');
    return ext.isEmpty ? '$roomId/$messageId' : '$roomId/$messageId.$ext';
  }

  /// Публичный URL медиа БЕЗ загрузки: getPublicUrl только строит строку,
  /// поэтому претензии могут получить ссылку до фактического upload.
  String mediaPublicUrl(String roomId, String messageId, String filename) {
    return _sb.storage
        .from('chat')
        .getPublicUrl(mediaPath(roomId, messageId, filename));
  }

  /// Файл/медиа
  Future<void> sendFile({
    required String roomId,
    required String? senderId,
    required String? senderName,
    required Uint8List bytes,
    required String filename,
    required String mime,
    String? body,
    String kind = 'file', // image | video | audio | file
    int? durationMs,
    int? width,
    int? height,
    String? messageId,
    List<ChatClaimTarget> claimTargets = const [],
  }) async {
    final id = messageId ?? _uuid.v4();
    final path = mediaPath(roomId, id, filename);

    final storage = _sb.storage.from('chat');
    await storage.uploadBinary(
      path,
      bytes,
      fileOptions: FileOptions(contentType: mime, upsert: true),
    );
    final publicUrl = storage.getPublicUrl(path);

    final preparedName = _prepareSenderName(senderId, senderName);
    final normalizedSenderId = (senderId ?? '').trim();
    if (preparedName != null &&
        preparedName.isNotEmpty &&
        normalizedSenderId.isNotEmpty) {
      _namesCache[normalizedSenderId] = preparedName;
    }

    try {
      await _sb.from('chat_messages').insert({
        'id': id,
        'room_id': roomId,
        'sender_id': senderId,
        'sender_name': preparedName,
        'kind': _kindFromMime(mime, fallback: kind),
        'body': body?.trim(),
        'file_url': publicUrl,
        'file_mime': mime,
        'duration_ms': durationMs,
        'width': width,
        'height': height,
        'created_at': DateTime.now().toIso8601String(),
        if (claimTargets.isNotEmpty)
          'claim_targets': [for (final t in claimTargets) t.toMap()],
      });
    } catch (_) {
      try {
        await storage.remove([path]);
      } catch (_) {
        // Очистка файла в Storage best-effort: основная ошибка — неуспешный insert.
      }
      throw Exception(
          'Не удалось сохранить сообщение с файлом. Загрузка отменена, попробуйте ещё раз.');
    }
  }

  String _kindFromMime(String mime, {String fallback = 'file'}) {
    final normalized = mime.toLowerCase().trim();
    if (normalized.startsWith('image/')) return 'image';
    if (normalized.startsWith('video/')) return 'video';
    if (normalized.startsWith('audio/')) return 'audio';
    return fallback == 'image' || fallback == 'video' || fallback == 'audio'
        ? fallback
        : 'file';
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
    _disposed = true;
    AuthHelper.sessionRevision.removeListener(_onLogicalSessionChanged);
    RealtimeSyncService.instance.unregisterOwner(this);
    for (final scheduler in _roomRefreshSchedulers.values) {
      scheduler.dispose();
    }
    _roomRefreshSchedulers.clear();
    for (final timer in _roomReconnectTimers.values) {
      timer.cancel();
    }
    _roomReconnectTimers.clear();
    _roomReconnectAttempts.clear();
    _desiredRooms.clear();
    _roomStatuses.clear();
    for (final waiter in _subscriptionWaiters.values) {
      if (!waiter.isCompleted) waiter.complete();
    }
    _subscriptionWaiters.clear();
    for (final roomId in _roomGenerations.keys.toList(growable: false)) {
      _roomGenerations[roomId] = (_roomGenerations[roomId] ?? 0) + 1;
    }
    for (final s in _subs.values) {
      if (s is StreamSubscription) {
        s.cancel();
      } else if (s is RealtimeChannel) {
        _sb.removeChannel(s);
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

  List<ChatMessage> _applyNames(List<ChatMessage> source,
      {Map<String, String>? extra}) {
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
      return current == msg.senderName
          ? msg
          : msg.copyWith(senderName: current);
    }

    if (id.isEmpty) return msg;

    unawaited(_fetchAndCacheName(id));
    return msg;
  }

  Future<Map<String, String>> _fetchNamesBatch(Set<String> ids) async {
    final result = <String, String>{};
    if (ids.isEmpty) return result;
    final sessionRevision = AuthHelper.sessionRevision.value;
    try {
      final res = await _sb
          .from('documents')
          .select('id, data')
          .filter('collection', 'eq', 'employees')
          .inFilter('id', ids.toList());
      if (_disposed || sessionRevision != AuthHelper.sessionRevision.value) {
        return result;
      }
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
    if (senderId.isEmpty ||
        _namesCache.containsKey(senderId) ||
        _pendingNames.contains(senderId)) {
      return;
    }
    final sessionRevision = AuthHelper.sessionRevision.value;
    _pendingNames.add(senderId);
    try {
      final dynamic res = await _sb
          .from('documents')
          .select('id, data')
          .filter('collection', 'eq', 'employees')
          .eq('id', senderId)
          .limit(1);
      if (_disposed || sessionRevision != AuthHelper.sessionRevision.value) {
        return;
      }

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
    } catch (_) {
    } finally {
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
