import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import 'dart:async';

import '../../services/app_auth.dart';
import '../../services/audit_log_service.dart';
import '../../services/attachment_service.dart';
import '../../services/realtime_sync_service.dart';
import '../../utils/network_failures.dart';

import '../orders/order_model.dart';
import '../orders/order_queue_service.dart';
import '../orders/production_ids.dart' as production_ids;
import '../orders/stage_queue_builder.dart' as stage_queue;
import 'local_write_guard.dart';
import 'task_completion_rules.dart';
import 'quantity_status_service.dart';
import 'stage_event_ops.dart';
import 'stage_event_outbox.dart';
import 'stage_quantity_records.dart';
import 'stage_sequence_utils.dart';
import 'task_model.dart';

/// Человеческое объяснение неудавшейся записи этапа.
///
/// Обрыв связи и отказ сервера цех должен различать: в первом случае действие
/// надо повторить, во втором — звать техлида.
String describeStageWriteFailure(Object error) {
  if (isTransientNetworkFailure(error)) {
    return 'Нет связи с сервером — действие не сохранено. '
        'Повторите, когда связь появится.';
  }
  if (error is PostgrestException) {
    final message = error.message.trim();
    if (message.isNotEmpty) return message;
  }
  return 'Не удалось сохранить действие: $error';
}

/// Очередь повторов на диске планшета.
///
/// Одна строка на всю очередь: она короткая (несколько намерений), а атомарная
/// запись целиком избавляет от полусохранённого состояния — ровно того, из-за
/// чего эта очередь и появилась.
class _PrefsStageOutboxStore implements StageOutboxStore {
  static const String _key = 'stage_event_outbox_v1';

  @override
  Future<String?> read() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_key);
  }

  @override
  Future<void> write(String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, value);
  }
}

const String _canonicalFlexoWorkplaceId = production_ids.wpFlexPrintingUuid;
const String _canonicalBobbinWorkplaceId = production_ids.wpBobbinUuid;

class _KnownWorkplaceAliasSpec {
  const _KnownWorkplaceAliasSpec({
    required this.canonicalId,
    required this.aliases,
    this.containsAny = const <String>{},
  });

  final String canonicalId;
  final Set<String> aliases;
  final Set<String> containsAny;

  bool matches(String value) {
    final normalized = _normalizeWorkplaceAlias(value);
    if (normalized.isEmpty) return false;
    if (aliases.contains(normalized)) return true;
    return containsAny.any(normalized.contains);
  }
}

String _normalizeWorkplaceAlias(String value) => value
    .trim()
    .toLowerCase()
    .replaceAll('ё', 'е')
    .replaceAll(RegExp(r'[‐‑‒–—−_/]+'), ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

const List<_KnownWorkplaceAliasSpec> _knownWorkplaceAliases = [
  _KnownWorkplaceAliasSpec(
    canonicalId: _canonicalFlexoWorkplaceId,
    aliases: {'w_flexoprint', 'w_flexo', 'флексопечать', 'флексо печать'},
    containsAny: {'флекс', 'flexo'},
  ),
  _KnownWorkplaceAliasSpec(
    canonicalId: _canonicalBobbinWorkplaceId,
    aliases: {
      'w_bobiner',
      'w_bobbin',
      'бобинорезка',
      'бабинорезка',
    },
    containsAny: {'бобин', 'бабин', 'bobbin', 'bobiner'},
  ),
  _KnownWorkplaceAliasSpec(
    canonicalId: stage_queue.kPackagingStageId,
    aliases: {'упаковка', 'упаков'},
    containsAny: {'упаков'},
  ),
  _KnownWorkplaceAliasSpec(
    canonicalId: stage_queue.kFriStageId,
    aliases: {'фри', 'fri'},
  ),
  _KnownWorkplaceAliasSpec(
    canonicalId: stage_queue.kWindowStageId,
    aliases: {'окно', 'window'},
  ),
  _KnownWorkplaceAliasSpec(
    canonicalId: stage_queue.kAutoBigStageId,
    aliases: {
      'автомат большой',
      'большой автомат',
      'auto big',
      'automatic big'
    },
    containsAny: {'автомат большой', 'большой автомат', 'auto big'},
  ),
  _KnownWorkplaceAliasSpec(
    canonicalId: stage_queue.kAutoSmallStageId,
    aliases: {
      'автомат маленький',
      'маленький автомат',
      'auto small',
      'automatic small',
    },
    containsAny: {'автомат маленький', 'маленький автомат', 'auto small'},
  ),
  _KnownWorkplaceAliasSpec(
    canonicalId: stage_queue.kTubeStageId,
    aliases: {'труба', 'tube'},
    containsAny: {'труба', 'tube'},
  ),
  _KnownWorkplaceAliasSpec(
    canonicalId: stage_queue.kSheetCutStageId,
    aliases: {'листорезка', 'листо резка', 'sheet cut', 'sheet cutter'},
    containsAny: {'листорез', 'sheet cut'},
  ),
  _KnownWorkplaceAliasSpec(
    canonicalId: stage_queue.kCuttingStageId,
    aliases: {'резка', 'cutting'},
  ),
  _KnownWorkplaceAliasSpec(
    canonicalId: stage_queue.kCardboardCuttingStageId,
    aliases: {'резка картона', 'картон резка', 'cardboard cutting'},
    containsAny: {'резка картона', 'cardboard cutting'},
  ),
  _KnownWorkplaceAliasSpec(
    canonicalId: stage_queue.kCardboardInsertStageId,
    aliases: {'вставка картона', 'картон вставка', 'cardboard insert'},
    containsAny: {'вставка картона', 'cardboard insert'},
  ),
  _KnownWorkplaceAliasSpec(
    canonicalId: stage_queue.kBottomWithCardboardAssemblyStageId,
    aliases: {
      'сборка дно картон',
      'сборка дна картон',
      'сборка дно+картон',
      'bottom cardboard assembly',
    },
  ),
  _KnownWorkplaceAliasSpec(
    canonicalId: stage_queue.kDieCutA1WorkplaceId,
    aliases: {'высечка a1', 'высечка а1', 'die cut a1'},
    containsAny: {'высечка a1', 'высечка а1', 'die cut a1'},
  ),
  _KnownWorkplaceAliasSpec(
    canonicalId: stage_queue.kDieCutA2WorkplaceId,
    aliases: {'высечка a2', 'высечка а2', 'die cut a2'},
    containsAny: {'высечка a2', 'высечка а2', 'die cut a2'},
  ),
  _KnownWorkplaceAliasSpec(
    canonicalId: stage_queue.kScotchStageId,
    aliases: {'скотч', 'scotch'},
  ),
  _KnownWorkplaceAliasSpec(
    canonicalId: stage_queue.kFromTwoSheetsStageId,
    aliases: {'с 2х листов', 'с двух листов', 'из 2х листов'},
  ),
  _KnownWorkplaceAliasSpec(
    canonicalId: stage_queue.kTubeAssemblyStageId,
    aliases: {'сборка трубы', 'tube assembly'},
    containsAny: {'сборка трубы', 'tube assembly'},
  ),
  _KnownWorkplaceAliasSpec(
    canonicalId: stage_queue.kBottomGlueWorkplaceId,
    aliases: {'склейка дна', 'клей дна', 'bottom glue'},
  ),
  _KnownWorkplaceAliasSpec(
    canonicalId: stage_queue.kBottomGlueAltWorkplaceId,
    aliases: {'склейка дна 2', 'клей дна 2', 'bottom glue 2'},
  ),
  _KnownWorkplaceAliasSpec(
    canonicalId: stage_queue.kBottomGlueSecondAltWorkplaceId,
    aliases: {'склейка дна 3', 'клей дна 3', 'bottom glue 3'},
  ),
  _KnownWorkplaceAliasSpec(
    canonicalId: stage_queue.kTwistedHandleWorkplaceId,
    aliases: {'крученая ручка', 'крученная ручка', 'twisted handle'},
    containsAny: {'крученая ручка', 'крученная ручка', 'twisted handle'},
  ),
  _KnownWorkplaceAliasSpec(
    canonicalId: stage_queue.kFlatHandleWorkplaceId,
    aliases: {'плоская ручка', 'flat handle'},
    containsAny: {'плоская ручка', 'flat handle'},
  ),
  _KnownWorkplaceAliasSpec(
    canonicalId: stage_queue.kSharedHandleWorkplaceId,
    aliases: {'ручная ручка', 'ручки вручную', 'manual handle'},
  ),
  _KnownWorkplaceAliasSpec(
    canonicalId: stage_queue.kDieCutHandleStageId,
    aliases: {'вырубка ручки', 'вырубка', 'die cut handle'},
  ),
];

class _StageSequenceData {
  final List<String> ids;
  final Map<String, Map<String, dynamic>> meta;
  final Map<String, String> groupByStageId;

  const _StageSequenceData({
    required this.ids,
    required this.meta,
    required this.groupByStageId,
  });
  const _StageSequenceData.empty()
      : ids = const [],
        meta = const {},
        groupByStageId = const {};
}

/// Итог правки количества: id-шники записи и формулировка «было → стало».
class QuantityEditResult {
  final String taskId;
  final String commentId;
  final String orderId;
  final String stageId;

  /// «Количество исправлено: 12000 шт → 13000 шт. Причина: …»
  final String summary;

  const QuantityEditResult({
    required this.taskId,
    required this.commentId,
    required this.orderId,
    required this.stageId,
    required this.summary,
  });
}

class TaskProvider with ChangeNotifier {
  final SupabaseClient _supabase = Supabase.instance.client;
  late final AttachmentService _attachmentService =
      AttachmentService(supabase: _supabase);

  final List<TaskModel> _tasks = [];
  // Полный перечит задач затирает список целиком. Если он стартовал до
  // локальной записи, а завершился после неё, действие цеха молча
  // откатывалось на экране — и сотрудник жал кнопку второй раз (см.
  // [LocalWriteGuard]). Все точечные изменения списка идут через [_setTask].
  final LocalWriteGuard<TaskModel> _localWrites =
      LocalWriteGuard<TaskModel>(idOf: (task) => task.id);
  final Map<String, String> _workplaceAliasToId = <String, String>{};
  // Имя и код рабочего места по id — из того же чтения workplaces, что и
  // алиасы. Последовательности этапов берут имена отсюда, а не отдельным
  // запросом на каждый заказ.
  final Map<String, Map<String, dynamic>> _workplaceMetaById = {};
  final Map<String, List<String>> _orderStageSequences = {};
  final Map<String, Map<String, String>> _orderStageNames = {};
  final Map<String, Map<String, String>> _orderStageGroupMaps = {};
  final Map<String, List<TaskCommentAttachment>> _attachmentsByComment = {};
  final Set<String> _loadingAttachmentKeys = <String>{};
  int _attachmentCacheGeneration = 0;
  final Set<String> _loadedStageSequenceOrderIds = <String>{};
  Future<void>? _activeRefresh;
  bool _refreshQueued = false;
  bool _disposed = false;
  // Страховочный поллинг на случай, когда realtime-сокет отвалился (цеховой
  // Wi-Fi). Раз в интервал проверяем ТОЛЬКО max(updated_at) (~50 байт) и
  // делаем полный refresh лишь если в БД что-то реально изменилось — почти без
  // нагрузки на сеть. См. [_startFallbackPoll].
  Timer? _fallbackPollTimer;
  DateTime? _lastLoadedMaxUpdatedAt;
  static const Duration _fallbackPollInterval = Duration(seconds: 8);

  TaskProvider() {
    RealtimeSyncService.instance.registerRefreshHandler(
      owner: this,
      resource: RealtimeResource.tasks,
      handler: refresh,
    );
    RealtimeSyncService.instance.registerRefreshHandler(
      owner: this,
      resource: RealtimeResource.taskAttachments,
      handler: () async => invalidateAttachmentCache(),
    );
    refresh();
    _startFallbackPoll();
  }

  List<TaskModel> get tasks => List.unmodifiable(_tasks);

  /// Единственная точка точечной правки списка задач.
  ///
  /// Кроме записи в список запоминает версию в [_localWrites]: перечит,
  /// который читал базу до этого момента, не должен вернуть строку назад.
  void _setTask(int index, TaskModel task) {
    _tasks[index] = task;
    _localWrites.record(task);
  }

  List<TaskCommentAttachment> attachmentsForComment(String commentId) =>
      List.unmodifiable(
          _attachmentsByComment[commentId] ?? const <TaskCommentAttachment>[]);
  List<String>? stageSequenceForOrder(String orderId) {
    final seq = _orderStageSequences[orderId];
    return seq == null ? null : List.unmodifiable(normalizeStageSequence(seq));
  }

  Map<String, String>? stageGroupMapForOrder(String orderId) {
    final map = _orderStageGroupMaps[orderId];
    return map == null ? null : Map.unmodifiable(map);
  }

  List<String>? stageGroupMembersForOrder(String orderId, String stageId) {
    final map = _orderStageGroupMaps[orderId];
    if (map == null || map.isEmpty) return null;
    final groupKey = map[stageId.trim()]?.trim();
    if (groupKey == null || groupKey.isEmpty) return null;
    final members = <String>[];
    for (final entry in map.entries) {
      if (entry.value == groupKey && !members.contains(entry.key)) {
        members.add(entry.key);
      }
    }
    return members.isEmpty ? null : List.unmodifiable(members);
  }

  Future<void> _ensureAuthed() async {
    await AppAuth.ensureSignedIn();
  }

  // Convert SQL row (snake_case) into TaskModel (camelCase map)
  TaskModel _rowToTask(Map<String, dynamic> row) {
    Map<String, dynamic> data = {};
    String _normalizeId(dynamic value) {
      final raw = value?.toString() ?? '';
      return raw.trim();
    }

    data['orderId'] = _normalizeId(row['order_id']);
    final rawStageId = row['stage_id'] ??
        row['stageId'] ??
        row['workplace_id'] ??
        row['workplaceId'];
    final resolvedStageId = _resolveWorkplaceId(_normalizeId(rawStageId));
    data['stageId'] = resolvedStageId;
    final rawStageGroupKey = row['stage_group_key'] ??
        row['stageGroupKey'] ??
        row['queue_stage_key'] ??
        row['queueStageKey'] ??
        row['group_key'];
    final normalizedGroupKey = _normalizeId(rawStageGroupKey);
    data['stageGroupKey'] =
        normalizedGroupKey.isEmpty ? resolvedStageId : normalizedGroupKey;
    data['capturedByWorkplaceId'] = _resolveWorkplaceId(_normalizeId(
      row['captured_by_workplace_id'] ?? row['capturedByWorkplaceId'],
    ));
    data['capturedByUserId'] = _normalizeId(
      row['captured_by_user_id'] ?? row['capturedByUserId'],
    );
    final capturedAt = row['captured_at'] ?? row['capturedAt'];
    if (capturedAt != null) {
      if (capturedAt is int) data['capturedAt'] = capturedAt;
      if (capturedAt is String) {
        final v = int.tryParse(capturedAt);
        if (v != null) data['capturedAt'] = v;
      }
    }
    data['status'] = (row['status'] ?? 'waiting').toString();
    data['spentSeconds'] = (row['spent_seconds'] as int?) ?? 0;
    final startedAt = row['started_at'];
    if (startedAt != null) {
      if (startedAt is int) data['startedAt'] = startedAt;
      if (startedAt is String) {
        // try parse int
        final v = int.tryParse(startedAt);
        if (v != null) data['startedAt'] = v;
      }
    }
    // assignees: text[]
    final a = row['assignees'];
    if (a is List) {
      data['assignees'] = List<String>.from(a.map((e) => e.toString()));
    }
    // comments: jsonb can be array or map
    final c = row['comments'];
    if (c is List) {
      // convert list -> map by id
      final Map<String, dynamic> mapped = {};
      for (final item in c) {
        if (item is Map && item['id'] != null) {
          mapped[item['id'].toString()] = item;
        }
      }
      data['comments'] = mapped;
    } else if (c is Map) {
      data['comments'] = c;
    }
    final id = (row['id'] ?? '').toString();
    return TaskModel.fromMap(data, id);
  }

  String _resolveWorkplaceId(String rawStageId) {
    final normalized = rawStageId.trim();
    if (normalized.isEmpty) return '';
    return _workplaceAliasToId[normalized.toLowerCase()] ?? normalized;
  }

  bool _isFlexoAlias(String text) => _knownWorkplaceAliases[0].matches(text);

  bool _isBobbinAlias(String text) => _knownWorkplaceAliases[1].matches(text);

  String? _detectWorkplaceIdByAlias(
      List<Map<String, dynamic>> rows, bool Function(String text) matcher) {
    for (final row in rows) {
      final id = row['id']?.toString().trim() ?? '';
      if (id.isEmpty) continue;
      final probes = [
        row['id'],
        row['name'],
        row['title'],
        row['short_name'],
        row['workplace_name'],
        row['stage_name'],
      ];
      for (final probe in probes) {
        final alias = probe?.toString().trim();
        if (alias == null || alias.isEmpty) continue;
        if (matcher(alias)) return id;
      }
    }
    return null;
  }

  Future<void> _loadWorkplaceAliases() async {
    Future<List<Map<String, dynamic>>> _readRows(String select) async {
      final rows = await _supabase.from('workplaces').select(select);
      if (rows is! List) return const <Map<String, dynamic>>[];
      return rows
          .whereType<Map>()
          .map((row) => Map<String, dynamic>.from(row))
          .toList(growable: false);
    }

    List<Map<String, dynamic>> rows = const <Map<String, dynamic>>[];
    try {
      rows = await _readRows('id, name, description, code');
    } catch (_) {
      try {
        rows = await _readRows('id, name');
      } catch (_) {
        rows = const <Map<String, dynamic>>[];
      }
    }

    final knownIds = rows
        .map((row) => row['id']?.toString().trim() ?? '')
        .where((id) => id.isNotEmpty)
        .toSet();

    final detectedByCanonicalId = <String, String>{};
    for (final spec in _knownWorkplaceAliases) {
      final detectedId = _detectWorkplaceIdByAlias(rows, spec.matches) ??
          (knownIds.contains(spec.canonicalId) ? spec.canonicalId : null);
      if (detectedId != null) {
        detectedByCanonicalId[spec.canonicalId] = detectedId;
      }
    }

    final detectedFlexoId = detectedByCanonicalId[_canonicalFlexoWorkplaceId];
    final detectedBobbinId = detectedByCanonicalId[_canonicalBobbinWorkplaceId];

    final aliases = <String, String>{};
    for (final spec in _knownWorkplaceAliases) {
      final detectedId = detectedByCanonicalId[spec.canonicalId];
      if (detectedId == null) continue;
      aliases[_normalizeWorkplaceAlias(spec.canonicalId)] = detectedId;
      aliases[_normalizeWorkplaceAlias(detectedId)] = detectedId;
      for (final alias in spec.aliases) {
        aliases[_normalizeWorkplaceAlias(alias)] = detectedId;
      }
    }
    for (final row in rows) {
      final id = row['id']?.toString().trim() ?? '';
      if (id.isEmpty) continue;
      final probes = [
        row['id'],
        row['name'],
        row['description'],
        row['code'],
        row['title'],
        row['short_name'],
        row['workplace_name'],
        row['stage_name'],
      ];
      for (final probe in probes) {
        final alias = probe?.toString().trim() ?? '';
        if (alias.isEmpty) continue;
        final normalizedAlias = _normalizeWorkplaceAlias(alias);
        if (normalizedAlias == 'w_flexoprint' || normalizedAlias == 'w_flexo') {
          if (detectedFlexoId != null) {
            aliases[normalizedAlias] = detectedFlexoId;
          }
          continue;
        }
        if (normalizedAlias == 'w_bobiner' || normalizedAlias == 'w_bobbin') {
          if (detectedBobbinId != null) {
            aliases[normalizedAlias] = detectedBobbinId;
          }
          continue;
        }
        aliases.putIfAbsent(normalizedAlias, () => id);
      }
    }

    _workplaceAliasToId
      ..clear()
      ..addAll(aliases);

    if (rows.isNotEmpty) {
      _workplaceMetaById
        ..clear()
        ..addAll(_workplaceMetaFromRows(rows));
    }
  }

  static Map<String, Map<String, dynamic>> _workplaceMetaFromRows(
      Iterable<Map<String, dynamic>> rows) {
    final result = <String, Map<String, dynamic>>{};
    for (final row in rows) {
      final id = row['id']?.toString().trim() ?? '';
      if (id.isEmpty) continue;
      final name = row['name']?.toString().trim() ?? '';
      final code = row['code']?.toString().trim() ?? '';
      result[id] = {
        if (name.isNotEmpty) 'stage_name': name,
        if (code.isNotEmpty) 'stage_code': code,
      };
    }
    return result;
  }

  String? stageNameForOrder(String orderId, String stageId) {
    if (orderId.isNotEmpty) {
      final names = _orderStageNames[orderId];
      final resolved = names?[stageId]?.trim();
      if (resolved != null && resolved.isNotEmpty) return resolved;
    }

    for (final entry in _orderStageNames.values) {
      final resolved = entry[stageId]?.trim();
      if (resolved != null && resolved.isNotEmpty) return resolved;
    }

    return null;
  }

  /// Макс. `updated_at` среди строк задач (для дешёвого фолбэк-поллинга).
  static DateTime? _maxUpdatedAt(List<Map<String, dynamic>> rows) {
    DateTime? maxTs;
    for (final r in rows) {
      final raw = r['updated_at'];
      if (raw == null) continue;
      final ts = DateTime.tryParse(raw.toString());
      if (ts == null) continue;
      if (maxTs == null || ts.isAfter(maxTs)) maxTs = ts;
    }
    return maxTs;
  }

  /// Страховка на случай, когда realtime не доставил событие (обрыв сокета):
  /// периодически проверяем лёгким запросом только max(updated_at) и делаем
  /// полный refresh, лишь если что-то изменилось с последней загрузки. Realtime
  /// остаётся основным путём — это только подстраховка, поэтому редкие
  /// пограничные случаи (напр. DELETE, не меняющий max) не критичны.
  void _startFallbackPoll() {
    _fallbackPollTimer?.cancel();
    _fallbackPollTimer =
        Timer.periodic(_fallbackPollInterval, (_) => _fallbackPollTick());
  }

  Future<void> _fallbackPollTick() async {
    if (_disposed) return;
    // Уже идёт загрузка — незачем ни проверять, ни дёргать ещё раз.
    if (_activeRefresh != null) return;
    try {
      final rows = await _supabase
          .from('tasks')
          .select('updated_at')
          .order('updated_at', ascending: false)
          .limit(1);
      if (_disposed) return;
      final list = List<Map<String, dynamic>>.from(rows as List);
      if (list.isEmpty) return;
      final ts = DateTime.tryParse((list.first['updated_at'] ?? '').toString());
      if (ts == null) return;
      final last = _lastLoadedMaxUpdatedAt;
      if (last == null || ts.isAfter(last)) {
        unawaited(refresh());
      }
    } catch (_) {
      // Тихо: это лишь страховка, сетевые ошибки не должны шуметь в логах.
    }
  }

  Future<void> refresh() {
    final active = _activeRefresh;
    if (active != null) {
      _refreshQueued = true;
      return active;
    }

    final future = _runRefreshLoop();
    _activeRefresh = future;
    return future.whenComplete(() {
      if (identical(_activeRefresh, future)) {
        _activeRefresh = null;
      }
    });
  }

  Future<void> _runRefreshLoop() async {
    do {
      _refreshQueued = false;
      await _refreshOnceWithRetry();
    } while (_refreshQueued);
    // Обновление списка означает, что связь есть — самый верный момент дослать
    // застрявшие действия, не дожидаясь таймера. Здесь же очередь читается с
    // диска: если планшет выключили с непустой очередью, она уйдёт при первом
    // обновлении, без участия человека.
    unawaited(flushStageOutbox());
  }

  /// Читает ВСЕ задания страницами.
  ///
  /// PostgREST отдаёт не больше 1000 строк за запрос и обрезает хвост молча,
  /// без ошибки. Таблица уже подходила к этому потолку, а срез при сортировке
  /// по возрастанию created_at отрезал бы самые СВЕЖИЕ задания: заказ выглядел
  /// бы «без задач» — висел бы на всех рабочих местах своих плановых этапов и
  /// никогда не считался завершённым. Вторым ключом сортировки идёт id, иначе
  /// строки с одинаковым created_at могут задвоиться или пропасть на границе
  /// страниц.
  Future<List<Map<String, dynamic>>> _fetchAllTaskRows() async {
    const pageSize = 1000;
    final rows = <Map<String, dynamic>>[];
    for (var offset = 0;; offset += pageSize) {
      final page = await _supabase
          .from('tasks')
          .select('*')
          .order('created_at')
          .order('id')
          .range(offset, offset + pageSize - 1);
      rows.addAll(List<Map<String, dynamic>>.from(page));
      if (page.length < pageSize) break;
    }
    return rows;
  }

  Future<void> _refreshOnceWithRetry() async {
    Set<String> orderIds = {};
    try {
      await _retryTransientSupabase('refresh tasks', () async {
        await _ensureAuthed();
        await _loadWorkplaceAliases();
        // Метка снимается ДО чтения: всё, что запишется локально, пока идут
        // эти запросы, снимок заведомо не увидит и затирать не должен.
        final fetchToken = _localWrites.beginFetch();
        final rowList = await _fetchAllTaskRows();
        if (_disposed) return;
        _tasks
          ..clear()
          ..addAll(_localWrites.reconcile(
            rowList.map(_rowToTask).toList(growable: false),
            fetchToken,
          ));
        // Опорная точка для дешёвого фолбэк-поллинга: макс. updated_at из уже
        // загруженных строк. Дальше поллинг сравнивает с ним лёгким запросом.
        _lastLoadedMaxUpdatedAt = _maxUpdatedAt(rowList);
        orderIds = _tasks.map((t) => t.orderId).toSet();
        _loadedStageSequenceOrderIds.clear();
      });
    } catch (e, st) {
      debugPrint('❌ refresh tasks error: $e\n$st');
      return;
    }
    // Задачи уже свежие — отдаём их экрану немедленно.
    //
    // Раньше notifyListeners() стоял ПОСЛЕ загрузки последовательностей
    // этапов. Та загрузка делает отдельный запрос на каждый заказ, и на сотне
    // заказов растягивалась на десятки секунд. Всё это время интерфейс держал
    // прежнее состояние: сотрудник жал «Проблема» или «Завершить», статус в
    // базе уже менялся, а кнопки не двигались — и приходилось перезаходить.
    if (_disposed) return;
    notifyListeners();

    // Последовательности этапов — вне таймаута и уже после первой отрисовки.
    await _preloadStageSequences(orderIds);
    if (_disposed) return;
    notifyListeners();
  }

  Future<T> _retryTransientSupabase<T>(
    String operation,
    Future<T> Function() action,
  ) async {
    Object? lastError;
    StackTrace? lastStackTrace;

    for (var attempt = 1; attempt <= 3; attempt += 1) {
      try {
        return await action().timeout(const Duration(seconds: 45));
      } catch (e, st) {
        lastError = e;
        lastStackTrace = st;
        // Таймауты не ретраим — повтор при медленном соединении только хуже.
        final isTimeout = e is TimeoutException;
        if (!_isTransientSupabaseError(e) || isTimeout || attempt == 3) {
          break;
        }
        debugPrint(
          '⚠️ $operation: transient Supabase connection error, '
          'retry $attempt/3: $e',
        );
        await Future<void>.delayed(Duration(milliseconds: 500 * attempt));
      }
    }

    Error.throwWithStackTrace(lastError!, lastStackTrace!);
  }

  bool _isTransientSupabaseError(Object error) =>
      isTransientNetworkFailure(error);

  // ===== updates =====

  Future<void> ensureStageSequencesForOrders(Iterable<String> orderIds) async {
    final missingOrderIds = orderIds
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .where((id) => !_loadedStageSequenceOrderIds.contains(id))
        .toSet();
    if (missingOrderIds.isEmpty) return;

    await _preloadStageSequences(missingOrderIds);
    notifyListeners();
  }

  Future<void> _preloadStageSequences(Iterable<String> orderIds) async {
    final ids = orderIds
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList(growable: false);
    if (ids.isEmpty) return;

    // Запрос уходит на каждый заказ отдельно. Последовательный цикл на сотне
    // заказов занимал десятки секунд — грузим пачками, сохраняя ограничение
    // по числу одновременных запросов, чтобы не задавить соединение.
    const int concurrency = 8;
    for (var start = 0; start < ids.length; start += concurrency) {
      final chunk = ids.skip(start).take(concurrency);
      await Future.wait(chunk.map(_loadStageSequenceForOrder));
    }
  }

  Future<void> _loadStageSequenceForOrder(String orderId) async {
    try {
      final data = await _fetchStageSequence(orderId);
      _loadedStageSequenceOrderIds.add(orderId);
      if (data.ids.isNotEmpty) {
        _orderStageSequences[orderId] = data.ids;
      } else {
        _orderStageSequences.remove(orderId);
      }
      if (data.groupByStageId.isNotEmpty) {
        _orderStageGroupMaps[orderId] = data.groupByStageId;
      } else {
        _orderStageGroupMaps.remove(orderId);
      }
      if (data.meta.isNotEmpty) {
        final names = <String, String>{};
        data.meta.forEach((stageId, meta) {
          final name = _readStageName(meta).trim();
          if (name.isNotEmpty) {
            names[stageId] = name;
          }
        });
        if (names.isNotEmpty) {
          _orderStageNames[orderId] = names;
        } else {
          _orderStageNames.remove(orderId);
        }
      } else {
        _orderStageNames.remove(orderId);
      }
    } catch (e) {
      // Один сбойный заказ не должен ронять загрузку всей пачки.
      debugPrint('⚠️ stage sequence load failed for $orderId: $e');
    }
  }

  int _readOrderIndex(Map<String, dynamic> row) {
    dynamic pick(List<String> keys) {
      for (final k in keys) {
        if (row.containsKey(k) && row[k] != null) return row[k];
      }
      return null;
    }

    final raw = pick(const [
      'order',
      'position',
      'idx',
      'seq',
      'step_no',
      'stepNo',
      'step',
      'sequence',
      'sequence_no'
    ]);
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    if (raw is String) {
      final trimmed = raw.trim();
      final parsed = int.tryParse(trimmed);
      if (parsed != null) return parsed;
      final alt = int.tryParse(trimmed.replaceAll(RegExp(r'[^0-9-]'), ''));
      if (alt != null) return alt;
    }
    return 0;
  }

  List<String> _readStageIds(Map<String, dynamic> row) {
    dynamic pick(List<String> keys) {
      for (final k in keys) {
        if (row.containsKey(k) && row[k] != null) return row[k];
      }
      return null;
    }

    final result = <String>[];
    void addCandidate(dynamic raw) {
      if (raw == null) return;
      final id = _resolveWorkplaceId(raw.toString().trim());
      if (id.isEmpty || result.contains(id)) return;
      result.add(id);
    }

    addCandidate(
      pick(const ['stage_id', 'stageId', 'workplace_id', 'workplaceId', 'id']),
    );

    dynamic workplaceIds = pick(const ['workplaceIds', 'workplace_ids']);
    if (workplaceIds is List) {
      for (final value in workplaceIds) {
        addCandidate(value);
      }
    } else if (workplaceIds is String) {
      for (final token in workplaceIds.split(',')) {
        addCandidate(token);
      }
    }

    dynamic alt = pick(const [
      'alternativeStageIds',
      'alternative_stage_ids',
      'allStageIds',
      'all_stage_ids',
      'stageIds',
      'stage_ids',
    ]);
    if (alt is List) {
      for (final value in alt) {
        addCandidate(value);
      }
    } else if (alt is String) {
      for (final token in alt.split(',')) {
        addCandidate(token);
      }
    }

    return result;
  }

  String _readStageName(Map<String, dynamic> row) {
    const keys = [
      'stage_name',
      'stageName',
      'workplace_name',
      'workplaceName',
      'workplace_title',
      'workplaceTitle',
      'title',
      'name',
    ];
    for (final key in keys) {
      if (!row.containsKey(key)) continue;
      final value = row[key];
      if (value == null) continue;
      final text = value.toString().trim();
      if (text.isNotEmpty) return text;
    }
    return '';
  }

  bool _isFlexoStage(String id, Map<String, dynamic> row) {
    final probes = <String>[
      id,
      _readStageName(row),
      if (row['stage_code'] != null) row['stage_code'].toString(),
    ];
    for (final probe in probes) {
      final lower = probe.toLowerCase();
      if (lower.contains('флекс') || lower.contains('flexo')) {
        return true;
      }
    }
    return false;
  }

  bool _isBobbinStage(String id, Map<String, dynamic> row) {
    final probes = <String>[
      id,
      _readStageName(row),
      if (row['stage_code'] != null) row['stage_code'].toString(),
    ];
    for (final probe in probes) {
      final lower = probe.toLowerCase();
      if (lower.contains('бобин') ||
          lower.contains('бабин') ||
          lower.contains('bobbin')) {
        return true;
      }
    }
    return false;
  }

  Future<Map<String, Map<String, dynamic>>> _workplaceMeta(
      List<String> stageIds) async {
    if (stageIds.isEmpty) return const {};
    // Обычно все рабочие места уже прочитаны вместе с алиасами. Раньше здесь
    // шёл отдельный запрос на каждый заказ при каждом обновлении задач — и с
    // несуществующими колонками title/short_name: ~230 тыс. ответов 400 в
    // сутки, а имена этапов не подгружались вовсе.
    final missing = stageIds
        .where((id) => !_workplaceMetaById.containsKey(id))
        .toList(growable: false);
    if (missing.isNotEmpty) {
      try {
        final rows = await _supabase
            .from('workplaces')
            .select('id, name, code')
            .inFilter('id', missing);
        _workplaceMetaById.addAll(_workplaceMetaFromRows(
            rows.map((row) => Map<String, dynamic>.from(row))));
        // Id, которого в workplaces нет, не переспрашиваем на каждом заказе.
        for (final id in missing) {
          _workplaceMetaById.putIfAbsent(id, () => const {});
        }
      } catch (_) {}
    }
    return {
      for (final id in stageIds)
        if (_workplaceMetaById[id]?.isNotEmpty ?? false)
          id: _workplaceMetaById[id]!,
    };
  }

  Future<_StageSequenceData> _fetchStageSequence(String orderId) async {
    await _ensureAuthed();
    String? orderCode;
    try {
      final order = await _supabase
          .from('orders')
          .select('assignment_id')
          .eq('id', orderId)
          .maybeSingle();
      final orderMap = order is Map
          ? Map<String, dynamic>.from(order as Map)
          : const <String, dynamic>{};
      orderCode = orderMap['assignment_id']?.toString();
    } catch (_) {}

    Future<_StageSequenceData> fromRows(dynamic rows) async {
      if (rows == null) return const _StageSequenceData.empty();
      final list = <Map<String, dynamic>>[];
      if (rows is List) {
        if (rows.isEmpty) return const _StageSequenceData.empty();
        for (final r in rows) {
          if (r is Map<String, dynamic>) {
            list.add(r);
          } else if (r is Map) {
            list.add(Map<String, dynamic>.from(r));
          }
        }
      } else if (rows is Map) {
        if (rows.isEmpty) return const _StageSequenceData.empty();
        final entries = rows.entries.toList()
          ..sort((a, b) {
            final ak = int.tryParse(a.key.toString());
            final bk = int.tryParse(b.key.toString());
            if (ak != null && bk != null) return ak.compareTo(bk);
            if (ak != null) return -1;
            if (bk != null) return 1;
            return a.key.toString().compareTo(b.key.toString());
          });
        for (final entry in entries) {
          if (entry.value is! Map) continue;
          final map = Map<String, dynamic>.from(entry.value as Map);
          if (!map.containsKey('order') &&
              !map.containsKey('position') &&
              !map.containsKey('idx') &&
              !map.containsKey('seq') &&
              !map.containsKey('step_no') &&
              !map.containsKey('stepNo') &&
              !map.containsKey('step') &&
              !map.containsKey('sequence') &&
              !map.containsKey('sequence_no')) {
            final parsed = int.tryParse(entry.key.toString());
            if (parsed != null) {
              map['order'] = parsed;
            }
          }
          list.add(map);
        }
      }
      if (list.isEmpty) return const _StageSequenceData.empty();
      const orderKeys = [
        'order',
        'position',
        'idx',
        'seq',
        'step_no',
        'stepNo',
        'step',
        'sequence',
        'sequence_no',
      ];
      bool hasOrderValue(Map<String, dynamic> row) {
        for (final key in orderKeys) {
          if (!row.containsKey(key)) continue;
          final value = row[key];
          if (value == null) continue;
          if (value is String && value.trim().isEmpty) continue;
          return true;
        }
        return false;
      }

      if (list.length > 1) {
        final indexed = list.asMap().entries.toList();
        indexed.sort((a, b) {
          final ai = hasOrderValue(a.value) ? _readOrderIndex(a.value) : a.key;
          final bi = hasOrderValue(b.value) ? _readOrderIndex(b.value) : b.key;
          if (ai != bi) return ai.compareTo(bi);
          if (a.key != b.key) return a.key.compareTo(b.key);
          final aStage = _readStageIds(a.value);
          final bStage = _readStageIds(b.value);
          final aKey = aStage.isEmpty ? '' : aStage.first;
          final bKey = bStage.isEmpty ? '' : bStage.first;
          return aKey.compareTo(bKey);
        });
        list
          ..clear()
          ..addAll(indexed.map((e) => e.value));
      }
      final result = <String>[];
      final filteredRows = <Map<String, dynamic>>[];
      final groupByStageId = <String, String>{};
      for (final m in list) {
        final stageIds = _readStageIds(m);
        if (stageIds.isEmpty) {
          continue;
        }
        final explicitGroupKey = (m['stage_group_key'] ??
                m['stageGroupKey'] ??
                m['queue_stage_key'] ??
                m['queueStageKey'] ??
                m['group_key'])
            ?.toString()
            .trim();
        final fallbackGroupKey = stageIds.join('|');
        final groupKey = explicitGroupKey != null && explicitGroupKey.isNotEmpty
            ? explicitGroupKey
            : fallbackGroupKey;
        for (final id in stageIds) {
          if (id.isNotEmpty) {
            groupByStageId[id] = groupKey;
          }
          if (id.isEmpty || result.contains(id)) {
            continue;
          }
          result.add(id);
          final normalizedRow = Map<String, dynamic>.from(m);
          normalizedRow['stage_id'] = id;
          normalizedRow['stageId'] = id;
          normalizedRow['stage_group_key'] = groupKey;
          filteredRows.add(normalizedRow);
        }
      }
      final normalizedIds = normalizeStageSequence(result);
      if (normalizedIds.isEmpty) return const _StageSequenceData.empty();
      final meta = await _workplaceMeta(normalizedIds);
      for (var i = 0; i < filteredRows.length; i++) {
        final id = result[i];
        final extras = meta[id];
        if (extras != null && extras.isNotEmpty) {
          // Только недостающее: имя из сохранённой очереди заказа главнее
          // текущего имени рабочего места.
          final row = filteredRows[i];
          extras.forEach((key, value) {
            final current = row[key]?.toString().trim() ?? '';
            if (current.isEmpty) row[key] = value;
          });
        }
      }
      final names = <String, Map<String, dynamic>>{};
      for (final row in filteredRows) {
        final stageIds = _readStageIds(row);
        for (final id in stageIds) {
          if (id.isEmpty) continue;
          names[id] = Map<String, dynamic>.from(row)
            ..['stage_id'] = id
            ..['stageId'] = id;
        }
      }

      return _StageSequenceData(
        ids: normalizedIds,
        meta: names,
        groupByStageId: groupByStageId,
      );
    }

    // Shared priority: normalized rows -> saved order queue -> legacy
    // production_plans.stages -> template fallback for old orders only.
    final savedQueue =
        await OrderQueueService(_supabase).loadSavedQueue(orderId);
    if (savedQueue.isNotEmpty) {
      final seq = await fromRows(savedQueue.rows);
      if (seq.ids.isNotEmpty) return seq;
    }

    // stageTemplateId is not read directly here: OrderQueueService already
    // applies templates only as the last fallback for legacy orders.

    // Fallback: derived/public views. They can contain auto-added or repeated
    // stages, so they are intentionally lower priority.
    try {
      final filters = <String>[
        'order_id.eq.$orderId',
        'order_code.eq.$orderId',
        if (orderCode != null && orderCode!.isNotEmpty && orderCode != orderId)
          'order_code.eq.$orderCode',
      ];
      // `seq` — физический порядок этапов в очереди заказа, `step_no` — номер
      // шага маршрута. Раньше запрашивался только `step_no`, и сортировка шла
      // по нему одному, без вторичного ключа.
      //
      // У заказа «Хороший год» после пересборки маршрута «Резка картона» и
      // «Сборка дно+картон» получили ОДИН И ТОТ ЖЕ step_no = 8. Порядок среди
      // равных PostgREST не определяет, поэтому неначатая «Резка картона»
      // вставала предшественником уже работавшей «Сборки дно+картон» — и
      // запирала её. На разных устройствах порядок мог выйти разным, отчего
      // блокировка выглядела случайной.
      final rows = await _supabase
          .from('v_order_plan_stages')
          .select(
            'stage_id, stage_group_key, stage_name, seq, step_no, order_id, '
            'order_code',
          )
          .or(filters.join(','))
          .order('seq', ascending: true)
          .order('step_no', ascending: true)
          .order('stage_id', ascending: true);
      final seq = await fromRows(rows);
      if (seq.ids.isNotEmpty) return seq;
    } catch (_) {}

    // Дальше источников нет. Прежние запасные чтения production.v_plan_with_stages
    // (схема production через REST не видна), workplace_stages и order_stages
    // (таблиц нет) всегда отвечали 404 — на каждый заказ без маршрута.
    return const _StageSequenceData.empty();
  }

  /// Создаёт отдельную задачу для пользователя (режим "Отдельный исполнитель").
  /// Клонирует order_id и stage_id, задаёт status=inProgress и started_at=now,
  /// назначает единственного исполнителя [userId].
  Future<void> cloneTaskForUser(TaskModel src, String userId) async {
    await _ensureAuthed();
    try {
      final now = DateTime.now().millisecondsSinceEpoch;
      final row = {
        'order_id': src.orderId,
        'stage_id': src.stageId,
        'stage_group_key': src.stageGroupKey,
        'captured_by_workplace_id': src.capturedByWorkplaceId,
        'captured_by_user_id': src.capturedByUserId,
        'captured_at': src.capturedAt,
        'status': 'inProgress',
        'spent_seconds': 0,
        'started_at': now,
        'assignees': [userId],
        'comments': [],
      };
      final inserted =
          await _supabase.from('tasks').insert(row).select().single();
      // push into local list
      final task = _rowToTask(Map<String, dynamic>.from(inserted as Map));
      _tasks.add(task);
      notifyListeners();
    } catch (e, st) {
      debugPrint('❌ cloneTaskForUser error: $e\n$st');
    }
  }

  Future<bool> updateStatus(
    String id,
    TaskStatus status, {
    int? spentSeconds,
    int? startedAt,
    bool clearStartedAt = false,
  }) async {
    final index = _tasks.indexWhere((t) => t.id == id);
    if (index == -1) return false;

    final current = _tasks[index];
    final shouldClearStartedAt = clearStartedAt ||
        (status != TaskStatus.inProgress && startedAt == null);
    final effectiveStartedAt =
        shouldClearStartedAt ? null : (startedAt ?? current.startedAt);
    final updated = current.copyWith(
      status: status,
      spentSeconds: spentSeconds ?? current.spentSeconds,
      startedAt: effectiveStartedAt,
      clearStartedAt: shouldClearStartedAt,
      comments: current.comments,
      assignees: current.assignees,
    );

    final updates = <String, dynamic>{
      'status': status.name,
      'spent_seconds': updated.spentSeconds,
      'started_at': effectiveStartedAt,
    };
    final bool becameInProgress = current.status != TaskStatus.inProgress &&
        status == TaskStatus.inProgress;
    final int? capturedAt =
        becameInProgress ? DateTime.now().millisecondsSinceEpoch : null;
    if (capturedAt != null) {
      updates['captured_by_workplace_id'] = current.stageId;
      updates['captured_at'] = capturedAt;
    }

    Map<String, dynamic>? persistedRow;
    try {
      var baseQuery = _supabase.from('tasks').update(updates).eq('id', id);
      // CAS-защита для старта этапа:
      // если другой сотрудник успел поменять статус первым,
      // повторный "старт" с устаревшего клиента не должен проходить.
      if (becameInProgress) {
        baseQuery = baseQuery.eq('status', current.status.name);
      }
      final rows = await (capturedAt != null
          ? baseQuery
              .or(
                'captured_by_workplace_id.is.null,captured_by_workplace_id.eq.${current.stageId}',
              )
              .select()
          : baseQuery.select());
      if (rows.isEmpty) {
        if (becameInProgress) {
          await refresh();
        }
        return false;
      }
      persistedRow = Map<String, dynamic>.from(rows.first);
    } catch (e, st) {
      debugPrint('❌ tasks.updateStatus error: $e\n$st');
      return false;
    }

    _setTask(index, _rowToTask(persistedRow));
    notifyListeners();

    if (capturedAt != null) {
      // Если этап состоит из нескольких рабочих мест (одна группа),
      // первый старт фиксирует "захват" для всех задач группы
      // и валидирует, что параллельного запуска конкурирующего места не произошло.
      final groupKey = current.stageGroupKey.trim();
      if (groupKey.isNotEmpty) {
        try {
          final conflicts = await _supabase
              .from('tasks')
              .select('id')
              .eq('order_id', current.orderId)
              .eq('stage_group_key', groupKey)
              .not('captured_by_workplace_id', 'is', null)
              .neq('captured_by_workplace_id', current.stageId)
              .limit(1);
          if ((conflicts as List).isNotEmpty) {
            await _supabase.from('tasks').update({
              'status': current.status.name,
              'started_at': current.startedAt,
              'captured_by_workplace_id': current.capturedByWorkplaceId,
              'captured_at': current.capturedAt,
            }).eq('id', current.id);
            await refresh();
            return false;
          }

          await _supabase
              .from('tasks')
              .update({
                'captured_by_workplace_id': current.stageId,
                'captured_at': capturedAt,
              })
              .eq('order_id', current.orderId)
              .eq('stage_group_key', groupKey)
              .isFilter('captured_by_workplace_id', null);
          for (var i = 0; i < _tasks.length; i++) {
            final task = _tasks[i];
            if (task.orderId == current.orderId &&
                task.stageGroupKey == groupKey &&
                task.capturedByWorkplaceId == null) {
              _setTask(
                i,
                task.copyWith(
                  capturedByWorkplaceId: current.stageId,
                  capturedAt: capturedAt,
                ),
              );
            }
          }
          notifyListeners();
        } catch (e, st) {
          debugPrint('⚠️ capture stage group update failed: $e\n$st');
        }
      }
    }

    await _syncStageGroupStatusToSharedSources(
      updated,
      status,
      spentSeconds: updated.spentSeconds,
      startedAt: updated.startedAt,
      completedAt: status == TaskStatus.completed
          ? DateTime.now().millisecondsSinceEpoch
          : null,
    );

    // if this task just became completed — check last-stage and update actual_qty
    if (status == TaskStatus.completed) {
      final orderId = updated.orderId;
      final stageId = updated.stageId;
      if (orderId.isNotEmpty && stageId.isNotEmpty) {
        await _maybeUpdateActualQtyAfterStage(orderId, stageId);
      }
    }

    // If all stage groups for order are finally completed — close the order
    final orderId = updated.orderId;
    if (orderId.isNotEmpty) {
      try {
        final rows =
            await _supabase.from('tasks').select('*').eq('order_id', orderId);
        final list = List<Map<String, dynamic>>.from(rows as List)
            .map(_rowToTask)
            .toList(growable: false);
        if (isOrderFinallyCompleted(list)) {
          await _supabase.from('orders').update({
            'status': OrderStatus.completed.name,
            'completed_at': DateTime.now().toUtc().toIso8601String(),
          }).eq('id', orderId);
          // Список заказов живёт в другом провайдере: без этого он ждал
          // эха realtime и показывал заказ незавершённым ещё минуту.
          RealtimeSyncService.instance
              .invalidateLocal(RealtimeResource.orders);
        }
      } catch (_) {}
    }

    return true;
  }

  Future<void> _syncStageGroupStatusToSharedSources(
    TaskModel task,
    TaskStatus status, {
    int? spentSeconds,
    int? startedAt,
    int? completedAt,
  }) async {
    final groupKey = task.stageGroupKey.trim().isNotEmpty
        ? task.stageGroupKey.trim()
        : task.stageId.trim();
    if (task.orderId.trim().isEmpty || groupKey.isEmpty) return;

    final shouldClearStartedAt =
        status != TaskStatus.inProgress && startedAt == null;
    final taskUpdates = <String, dynamic>{
      'status': status.name,
      if (spentSeconds != null) 'spent_seconds': spentSeconds,
      if (shouldClearStartedAt) 'started_at': null,
      if (!shouldClearStartedAt && startedAt != null) 'started_at': startedAt,
      if (completedAt != null) 'completed_at': completedAt,
    };
    final startedIso = startedAt == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(startedAt)
            .toUtc()
            .toIso8601String();
    final completedIso = completedAt == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(completedAt)
            .toUtc()
            .toIso8601String();
    final planUpdates = <String, dynamic>{
      'status': status.name,
      if (startedIso != null) 'started_at': startedIso,
      if (completedIso != null) ...{
        'finished_at': completedIso,
        'completed_at': completedIso,
      },
    };

    try {
      await _updateTaskStageGroup(
        orderId: task.orderId,
        groupKey: groupKey,
        updates: taskUpdates,
      );
      for (var i = 0; i < _tasks.length; i++) {
        final local = _tasks[i];
        if (local.orderId == task.orderId && local.stageGroupKey == groupKey) {
          _setTask(
            i,
            local.copyWith(
              status: status,
              spentSeconds: spentSeconds ?? local.spentSeconds,
              startedAt:
                  shouldClearStartedAt ? null : (startedAt ?? local.startedAt),
              clearStartedAt: shouldClearStartedAt,
            ),
          );
        }
      }
      notifyListeners();
    } catch (e, st) {
      debugPrint('⚠️ stage group task status sync failed: $e\n$st');
    }

    try {
      final plan = await _supabase
          .from('prod_plans')
          .select('id')
          .eq('order_id', task.orderId)
          .maybeSingle();
      final planId = plan != null ? plan['id']?.toString() : null;
      if (planId == null || planId.isEmpty) return;
      await _updateProdPlanStageGroup(
        planId: planId,
        groupKey: groupKey,
        updates: planUpdates,
      );
    } catch (e, st) {
      debugPrint('⚠️ prod_plan_stages status sync failed: $e\n$st');
    }
  }

  Future<void> _updateTaskStageGroup({
    required String orderId,
    required String groupKey,
    required Map<String, dynamic> updates,
  }) async {
    Future<void> run(Map<String, dynamic> payload) async {
      await _supabase
          .from('tasks')
          .update(payload)
          .eq('order_id', orderId)
          .eq('stage_group_key', groupKey);
    }

    try {
      await run(updates);
    } catch (error) {
      if (!_isMissingColumnError(error, 'completed_at')) rethrow;
      final fallback = Map<String, dynamic>.from(updates)
        ..remove('completed_at');
      await run(fallback);
    }
  }

  Future<void> _updateProdPlanStageGroup({
    required String planId,
    required String groupKey,
    required Map<String, dynamic> updates,
  }) async {
    Future<void> run(Map<String, dynamic> payload) async {
      await _supabase
          .from('prod_plan_stages')
          .update(payload)
          .eq('plan_id', planId)
          .eq('stage_group_key', groupKey);
    }

    try {
      await run(updates);
    } catch (error) {
      if (!_isMissingColumnError(error, 'completed_at')) rethrow;
      final fallback = Map<String, dynamic>.from(updates)
        ..remove('completed_at');
      await run(fallback);
    }
  }

  bool _isMissingColumnError(Object error, String columnName) {
    if (error is! PostgrestException) return false;
    final message = error.message.toLowerCase();
    return message.contains(columnName.toLowerCase()) &&
        (error.code == '42703' || error.code == 'PGRST204');
  }

  /// Возвращает завершённый этап в работу.
  ///
  /// Ничего не удаляет: время, количество и комментарии остаются на задачах —
  /// после возобновления сотрудник дополняет их, а не начинает с нуля. Снимаем
  /// только признаки завершения (статус, started_at/completed_at) — у задач
  /// группы, в плане производства и, если заказ успел закрыться, у заказа.
  ///
  /// Складские последствия закрытия заказа (финализация резервов бумаги) не
  /// откатываются: их отменяют отдельной складской операцией.
  ///
  /// Возвращает null при успехе или текст ошибки для снекбара.
  Future<String?> reopenStageGroup({
    required TaskModel task,
    required String actorUserId,
  }) async {
    final orderId = task.orderId.trim();
    final groupKey = stageGroupKeyForTask(task);
    if (orderId.isEmpty || groupKey.isEmpty) {
      return 'Этап не привязан к заказу.';
    }

    final groupTasks = _tasks
        .where((t) =>
            t.orderId == orderId && stageGroupKeyForTask(t) == groupKey)
        .toList(growable: false);
    if (groupTasks.isEmpty) return 'Задачи этапа не найдены.';
    if (!isStageGroupFinallyCompleted(groupTasks)) {
      return 'Этап не завершён — возобновлять нечего.';
    }

    final completedIds = groupTasks
        .where((t) => t.status == TaskStatus.completed)
        .map((t) => t.id.trim())
        .where((id) => id.isNotEmpty)
        .toList(growable: false);
    if (completedIds.isEmpty) return 'Завершённых задач этапа не найдено.';

    try {
      // Отметка в ленте: история этапа дополняется, а не переписывается.
      for (final id in completedIds) {
        await addComment(
          taskId: id,
          type: 'stage_reopened',
          text: 'Этап возобновлён после завершения',
          userId: actorUserId,
        );
      }

      await _clearTaskCompletion(completedIds);
      await _clearPlanStageCompletion(orderId: orderId, groupKey: groupKey);
      await _reopenOrderIfCompleted(orderId);
    } catch (e, st) {
      debugPrint('❌ reopenStageGroup: $e\n$st');
      return 'Не удалось возобновить этап: $e';
    }

    await refresh();
    RealtimeSyncService.instance.invalidateLocal(RealtimeResource.orders);
    return null;
  }

  Future<void> _clearTaskCompletion(List<String> taskIds) async {
    // Обновляем строго по id: у части задач stage_group_key пуст, и фильтр
    // по группе прошёл бы мимо них.
    Future<void> run(Map<String, dynamic> payload) async {
      await _supabase.from('tasks').update(payload).inFilter('id', taskIds);
    }

    final updates = <String, dynamic>{
      'status': TaskStatus.waiting.name,
      'started_at': null,
      'completed_at': null,
    };
    try {
      await run(updates);
    } catch (error) {
      if (!_isMissingColumnError(error, 'completed_at')) rethrow;
      await run(Map<String, dynamic>.from(updates)..remove('completed_at'));
    }
  }

  Future<void> _clearPlanStageCompletion({
    required String orderId,
    required String groupKey,
  }) async {
    try {
      final plan = await _supabase
          .from('prod_plans')
          .select('id')
          .eq('order_id', orderId)
          .maybeSingle();
      final planId = plan == null ? null : plan['id']?.toString();
      if (planId == null || planId.isEmpty) return;

      Future<void> run(Map<String, dynamic> payload) async {
        await _supabase
            .from('prod_plan_stages')
            .update(payload)
            .eq('plan_id', planId)
            .eq('stage_group_key', groupKey);
      }

      final updates = <String, dynamic>{
        'status': TaskStatus.waiting.name,
        'finished_at': null,
        'completed_at': null,
      };
      try {
        await run(updates);
      } catch (error) {
        if (!_isMissingColumnError(error, 'completed_at')) rethrow;
        await run(Map<String, dynamic>.from(updates)..remove('completed_at'));
      }
    } catch (e, st) {
      debugPrint('⚠️ prod_plan_stages reopen sync failed: $e\n$st');
    }
  }

  Future<void> _reopenOrderIfCompleted(String orderId) async {
    try {
      final row = await _supabase
          .from('orders')
          .select('status')
          .eq('id', orderId)
          .maybeSingle();
      final status = (row?['status'] ?? '').toString();
      if (status != OrderStatus.completed.name) return;

      try {
        await _supabase.from('orders').update({
          'status': OrderStatus.in_production.name,
          'completed_at': null,
        }).eq('id', orderId);
      } catch (error) {
        if (!_isMissingColumnError(error, 'completed_at')) rethrow;
        await _supabase
            .from('orders')
            .update({'status': OrderStatus.in_production.name})
            .eq('id', orderId);
      }
    } catch (e, st) {
      debugPrint('⚠️ order reopen sync failed: $e\n$st');
    }
  }

  Future<bool> reportProblem({
    required String taskId,
    required String text,
    required String userId,
    required List<String> participantsSnapshot,
    required List<String> subjectUserIds,
    String? workplaceId,
    String? executionMode,
    List<AttachmentDraft> attachments = const <AttachmentDraft>[],
  }) async {
    final localIndex = _tasks.indexWhere((task) => task.id == taskId);
    if (localIndex == -1) return false;
    final localTask = _tasks[localIndex];
    if (localTask.status != TaskStatus.inProgress) return false;

    final now = DateTime.now().toUtc();
    final timestamp = now.millisecondsSinceEpoch;
    final commentId = '$timestamp';
    final normalizedSubjects = subjectUserIds
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList(growable: false);
    if (normalizedSubjects.isEmpty) normalizedSubjects.add(userId);

    final uploaded = <TaskCommentAttachment>[];
    List<Map<String, dynamic>> previousComments =
        const <Map<String, dynamic>>[];
    var commentsPersisted = false;
    var statusPersisted = false;
    Map<String, dynamic>? previousTaskUpdates;

    Future<void> cleanupUploads() async {
      for (final attachment in uploaded) {
        await _attachmentService.removeAttachment(attachment);
      }
    }

    try {
      for (final draft in attachments) {
        uploaded.add(await _attachmentService.uploadTaskCommentAttachment(
          draft: draft,
          taskId: localTask.id,
          orderId: localTask.orderId,
          stageId: localTask.stageId,
          commentId: commentId,
          userId: userId,
        ));
      }

      final row = await _supabase
          .from('tasks')
          .select(
            'comments,status,spent_seconds,started_at,'
            'captured_by_workplace_id,captured_at,captured_by_user_id',
          )
          .eq('id', taskId)
          .single();
      final status = (row['status'] ?? '').toString();
      if (status != TaskStatus.inProgress.name) {
        await cleanupUploads();
        await refresh();
        return false;
      }

      previousTaskUpdates = {
        'status': row['status'],
        'spent_seconds': row['spent_seconds'],
        'started_at': row['started_at'],
        'captured_by_workplace_id': row['captured_by_workplace_id'],
        'captured_at': row['captured_at'],
        'captured_by_user_id': row['captured_by_user_id'],
      };
      previousComments = _normalizeComments(row['comments']);
      final comments = previousComments
          .map((comment) => Map<String, dynamic>.from(comment))
          .toList(growable: true);
      comments.add({
        'id': commentId,
        'type': 'problem',
        'text': text,
        'userId': userId,
        'timestamp': timestamp,
      });

      for (final subjectUserId in normalizedSubjects) {
        final openIndex = _findOpenTimeEventIndex(comments, subjectUserId);
        if (openIndex != null) {
          final open = comments[openIndex];
          final openEvent = TaskTimeEvent.fromPayload(
            open['text']?.toString() ?? '',
            open['id']?.toString() ?? '',
            _parseCommentTimestamp(open['timestamp']),
            open['userId']?.toString() ?? '',
          );
          if (openEvent != null && openEvent.endTime == null) {
            open['text'] = TaskTimeEvent.encodePayload(
              openEvent.copyWith(endTime: now, note: text),
            );
          }
        }

        final event = TaskTimeEvent(
          id: '$timestamp-$subjectUserId',
          type: TaskTimeType.problem,
          startTime: now,
          endTime: null,
          initiatedBy: userId,
          subjectUserId: subjectUserId,
          taskId: localTask.id,
          workplaceId: workplaceId ?? localTask.stageId,
          participantsSnapshot: participantsSnapshot,
          executionMode: executionMode,
          helperId: subjectUserId == userId ? null : subjectUserId,
          note: text,
        );
        comments.add({
          'id': event.id,
          'type': 'time_event',
          'text': TaskTimeEvent.encodePayload(event),
          'userId': subjectUserId,
          'timestamp': timestamp,
        });
      }

      comments.sort((a, b) => _parseCommentTimestamp(a['timestamp'])
          .compareTo(_parseCommentTimestamp(b['timestamp'])));
      await _supabase
          .from('tasks')
          .update({'comments': comments}).eq('id', taskId);
      commentsPersisted = true;

      final spentSeconds = localTask.startedAt == null
          ? localTask.spentSeconds
          : localTask.spentSeconds +
              ((DateTime.now().millisecondsSinceEpoch - localTask.startedAt!) ~/
                  1000);
      final updates = <String, dynamic>{
        'status': TaskStatus.problem.name,
        'spent_seconds': spentSeconds,
        'started_at': null,
        'captured_by_workplace_id': null,
        'captured_at': null,
        'captured_by_user_id': null,
      };
      final statusRows = await _supabase
          .from('tasks')
          .update(updates)
          .eq('id', taskId)
          .eq('status', TaskStatus.inProgress.name)
          .select();
      if ((statusRows as List).isEmpty) {
        await _supabase
            .from('tasks')
            .update({'comments': previousComments}).eq('id', taskId);
        await cleanupUploads();
        await refresh();
        return false;
      }

      statusPersisted = true;

      final groupKey = localTask.stageGroupKey.trim();
      if (groupKey.isNotEmpty) {
        await _supabase
            .from('tasks')
            .update({
              'status': TaskStatus.problem.name,
              'spent_seconds': spentSeconds,
              'started_at': null,
              'captured_by_workplace_id': null,
              'captured_at': null,
              'captured_by_user_id': null,
            })
            .eq('order_id', localTask.orderId)
            .eq('stage_group_key', groupKey);
      }

      await _syncStageGroupStatusToSharedSources(
        localTask.copyWith(
          status: TaskStatus.problem,
          spentSeconds: spentSeconds,
          startedAt: null,
          clearStartedAt: true,
        ),
        TaskStatus.problem,
        spentSeconds: spentSeconds,
        startedAt: null,
      );

      if (uploaded.isNotEmpty) {
        _attachmentsByComment[commentId] = uploaded;
      }
      await refresh();
      notifyListeners();
      return true;
    } catch (e, st) {
      if (statusPersisted && previousTaskUpdates != null) {
        try {
          await _supabase
              .from('tasks')
              .update(previousTaskUpdates)
              .eq('id', taskId);
        } catch (_) {}
      }
      if (commentsPersisted) {
        try {
          await _supabase
              .from('tasks')
              .update({'comments': previousComments}).eq('id', taskId);
        } catch (_) {}
      }
      await cleanupUploads();
      debugPrint('❌ reportProblem error: $e\n$st');
      rethrow;
    }
  }

  Future<void> createCommentWithAttachments({
    required String taskId,
    required String type,
    required String text,
    required String userId,
    List<AttachmentDraft> attachments = const <AttachmentDraft>[],
  }) async {
    final task = _tasks.cast<TaskModel?>().firstWhere(
          (item) => item?.id == taskId,
          orElse: () => null,
        );
    if (task == null) {
      await addComment(
        taskId: taskId,
        type: type,
        text: text,
        userId: userId,
      );
      return;
    }

    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final commentId = '$timestamp';
    final uploaded = <TaskCommentAttachment>[];
    try {
      for (final draft in attachments) {
        uploaded.add(await _attachmentService.uploadTaskCommentAttachment(
          draft: draft,
          taskId: task.id,
          orderId: task.orderId,
          stageId: task.stageId,
          commentId: commentId,
          userId: userId,
        ));
      }
      await _insertCommentWithId(
        taskId: taskId,
        id: commentId,
        type: type,
        text: text,
        userId: userId,
        timestamp: timestamp,
      );
      if (uploaded.isNotEmpty) {
        _attachmentsByComment[commentId] = uploaded;
        notifyListeners();
      }
    } catch (e, st) {
      for (final attachment in uploaded) {
        await _attachmentService.removeAttachment(attachment);
      }
      debugPrint('❌ createCommentWithAttachments error: $e\n$st');
      rethrow;
    }
  }

  Future<void> _insertCommentWithId({
    required String taskId,
    required String id,
    required String type,
    required String text,
    required String userId,
    required int timestamp,
  }) async {
    final row = await _supabase
        .from('tasks')
        .select('comments')
        .eq('id', taskId)
        .single();
    final comments = _normalizeComments(row['comments']);
    comments.add({
      'id': id,
      'type': type,
      'text': text,
      'userId': userId,
      'timestamp': timestamp,
    });
    comments.sort((a, b) => _parseCommentTimestamp(a['timestamp'])
        .compareTo(_parseCommentTimestamp(b['timestamp'])));
    await _supabase
        .from('tasks')
        .update({'comments': comments}).eq('id', taskId);

    final idx = _tasks.indexWhere((t) => t.id == taskId);
    if (idx != -1) {
      final current = _tasks[idx];
      final updatedComments = List<TaskComment>.from(current.comments)
        ..add(TaskComment(
          id: id,
          type: type,
          text: text,
          userId: userId,
          timestamp: timestamp,
        ))
        ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
      _setTask(idx, current.copyWith(comments: updatedComments));
      notifyListeners();
    }
  }

  Future<void> loadAttachmentsForComments(Iterable<String> commentIds) async {
    final ids =
        commentIds.map((id) => id.trim()).where((id) => id.isNotEmpty).toSet();
    final missing = ids
        .where((id) => !_attachmentsByComment.containsKey(id))
        .toList(growable: false);
    if (missing.isEmpty) return;
    final key = 'comments:${missing.join(',')}';
    if (_loadingAttachmentKeys.contains(key)) return;
    _loadingAttachmentKeys.add(key);
    final generation = _attachmentCacheGeneration;
    try {
      final loaded = await _attachmentService.loadTaskCommentAttachments(
        commentIds: missing,
      );
      if (generation != _attachmentCacheGeneration) return;
      for (final id in missing) {
        _attachmentsByComment[id] = loaded
            .where((attachment) => attachment.commentId == id)
            .toList(growable: false);
      }
      notifyListeners();
    } catch (e, st) {
      debugPrint('❌ loadAttachmentsForComments error: $e\n$st');
    } finally {
      _loadingAttachmentKeys.remove(key);
    }
  }

  /// Realtime invalidates only the attachment cache. The existing workspace
  /// loader will request the visible comments again on the next rebuild.
  void invalidateAttachmentCache() {
    _attachmentCacheGeneration += 1;
    _attachmentsByComment.clear();
    _loadingAttachmentKeys.clear();
    notifyListeners();
  }

  Future<void> loadAttachmentsForOrder(String orderId,
      {String? stageId}) async {
    final key = 'order:$orderId:${stageId ?? ''}';
    if (_loadingAttachmentKeys.contains(key)) return;
    _loadingAttachmentKeys.add(key);
    final generation = _attachmentCacheGeneration;
    try {
      final loaded = await _attachmentService.loadTaskCommentAttachments(
        orderId: orderId,
        stageId: stageId,
      );
      if (generation != _attachmentCacheGeneration) return;
      for (final attachment in loaded) {
        final list = _attachmentsByComment.putIfAbsent(
          attachment.commentId,
          () => <TaskCommentAttachment>[],
        );
        final index = list.indexWhere((item) => item.id == attachment.id);
        if (index == -1) {
          list.add(attachment);
        } else {
          list[index] = attachment;
        }
      }
      notifyListeners();
    } catch (e, st) {
      debugPrint('❌ loadAttachmentsForOrder error: $e\n$st');
    } finally {
      _loadingAttachmentKeys.remove(key);
    }
  }

  Future<void> removeStorageObject(String storagePath) =>
      _attachmentService.removeStorageObject(storagePath);

  /// Возвращает false, если комментарий не сохранён.
  ///
  /// Вызывающий обязан на это реагировать: раньше сбой уходил в debugPrint, и
  /// пересмена, у которой не долетели `shift_pause_state` и `shift_pause`,
  /// выглядела для оператора успешной.
  /// Дописывает комментарий к заданию.
  ///
  /// Через этот метод идут не только реплики, но и вся история этапа: отметки
  /// количества, режимы работы, проблемы, пересмены. Раньше он читал весь
  /// массив `comments`, дописывал в него запись и возвращал массив назад
  /// целиком. Отсюда два хронических сбоя:
  ///
  ///   * второй планшет, писавший в те же секунды, затирал чужую запись —
  ///     она пропадала бесследно;
  ///   * обрыв связи посреди записи терял её молча.
  ///
  /// Теперь уходит намерение «добавь комментарий»: сервер дописывает его к
  /// свежим данным, а не долетевшее ждёт связи в очереди повторов.
  Future<bool> addComment(
      {required String taskId,
      required String type,
      required String text,
      required String userId}) async {
    final applied = await applyStageEvents(
      taskId: taskId,
      label: 'Запись в задание',
      ops: [
        StageEventOps.comment(type: type, text: text, userId: userId),
      ],
    );
    if (!applied) return false;

    if (type == 'start') {
      await _markStageCapturedBy(taskId: taskId, userId: userId);
    }
    return true;
  }

  /// Фиксирует, кто фактически захватил этап.
  ///
  /// Отдельный столбец, а не комментарий, поэтому идёт своим запросом. Условие
  /// `is null` оставлено намеренно: первый захвативший остаётся навсегда, и
  /// повторный вызов (в том числе повтор из очереди) ничего не переписывает.
  Future<void> _markStageCapturedBy({
    required String taskId,
    required String userId,
  }) async {
    final task = _tasks.cast<TaskModel?>().firstWhere(
          (t) => t?.id == taskId,
          orElse: () => null,
        );
    if (task == null) return;
    if (task.capturedByUserId != null && task.capturedByUserId!.isNotEmpty) {
      return;
    }
    final groupKey = task.stageGroupKey.trim();
    try {
      await _supabase
          .from('tasks')
          .update({'captured_by_user_id': userId})
          .eq('order_id', task.orderId)
          .eq('stage_group_key', groupKey)
          .isFilter('captured_by_user_id', null);
      for (var i = 0; i < _tasks.length; i++) {
        final local = _tasks[i];
        if (local.orderId == task.orderId &&
            local.stageGroupKey == groupKey &&
            (local.capturedByUserId == null ||
                local.capturedByUserId!.isEmpty)) {
          _setTask(i, local.copyWith(capturedByUserId: userId));
        }
      }
      if (!_disposed) notifyListeners();
    } catch (e, st) {
      // Не критично: столбец только для отчёта «кто запустил этап», сама
      // история этапа уже записана.
      debugPrint('⚠️ capture user update failed: $e — $st');
    }
  }

  List<Map<String, dynamic>> _normalizeComments(dynamic value) {
    final comments = <Map<String, dynamic>>[];
    if (value is List) {
      for (final item in value) {
        if (item is Map) {
          comments.add(Map<String, dynamic>.from(item));
        }
      }
    } else if (value is Map) {
      value.forEach((_, v) {
        if (v is Map) {
          comments.add(Map<String, dynamic>.from(v));
        }
      });
    }
    return comments;
  }

  int _parseCommentTimestamp(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) {
      final parsed = int.tryParse(value.trim());
      if (parsed != null) return parsed;
    }
    return 0;
  }

  List<TaskComment> _toTaskComments(List<Map<String, dynamic>> comments) {
    final result = <TaskComment>[];
    for (final raw in comments) {
      final id = (raw['id'] ?? '').toString();
      result.add(TaskComment.fromMap(raw, id));
    }
    result.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return result;
  }

  int? _findOpenTimeEventIndex(
      List<Map<String, dynamic>> comments, String subjectUserId) {
    int? openIndex;
    int latestTs = -1;
    for (var i = 0; i < comments.length; i++) {
      final comment = comments[i];
      if ((comment['type'] ?? '') != 'time_event') continue;
      final text = comment['text']?.toString() ?? '';
      final timestamp = _parseCommentTimestamp(comment['timestamp']);
      final event = TaskTimeEvent.fromPayload(
          text,
          comment['id']?.toString() ?? '',
          timestamp,
          comment['userId']?.toString() ?? '');
      if (event == null) continue;
      if (event.subjectUserId != subjectUserId) continue;
      if (event.endTime != null) continue;
      if (timestamp > latestTs) {
        latestTs = timestamp;
        openIndex = i;
      }
    }
    return openIndex;
  }

  /// Открывает интервал времени сотруднику.
  ///
  /// Раньше метод читал `comments`, дописывал событие и возвращал ВЕСЬ массив
  /// назад. Два планшета, нажавшие кнопки в пределах одного round-trip,
  /// затирали записи друг друга, а обрыв связи посреди этого терял событие
  /// молча — ровно так пропадали отметки пересмены.
  ///
  /// Теперь уходит намерение «открой интервал»: сервер применяет его к свежим
  /// данным в одной транзакции, а не долетевшее ждёт связи в очереди повторов.
  ///
  /// Поведение сохранено один в один (`open_interval` в `task_apply_ops`):
  /// если у сотрудника уже открыт интервал того же типа — ничего не меняется;
  /// интервал другого типа закрывается тем же моментом времени.
  Future<bool> recordTimeEvent({
    required TaskModel task,
    required TaskTimeType type,
    required String initiatedBy,
    required String subjectUserId,
    required String workplaceId,
    required List<String> participantsSnapshot,
    String? executionMode,
    String? helperId,
    String? note,
  }) {
    return applyStageEvents(
      taskId: task.id,
      label: 'Отметка времени',
      ops: [
        StageEventOps.openInterval(
          subject: subjectUserId,
          type: taskTimeTypeToString(type),
          initiatedBy: initiatedBy,
          workplaceId: workplaceId,
          participants: participantsSnapshot,
          executionMode: executionMode,
          helperId: helperId,
          note: note,
        ),
      ],
    );
  }

  /// Закрывает открытый интервал сотрудника.
  ///
  /// Как и [recordTimeEvent], ушёл от «прочитать-поправить-записать весь
  /// массив» к намерению «закрой интервал». Если открытого интервала нет,
  /// сервер ничего не делает — прежний ранний выход сохранён.
  ///
  /// Именно потерянное закрытие мотало счётчик этапа 16 часов подряд: запрос
  /// не долетал, и никто об этом не узнавал. Теперь он доедет сам.
  Future<bool> closeOpenTimeEvent({
    required TaskModel task,
    required String initiatedBy,
    required String subjectUserId,
    String? note,
  }) {
    return applyStageEvents(
      taskId: task.id,
      label: 'Закрытие интервала',
      ops: [
        StageEventOps.closeInterval(subject: subjectUserId, note: note),
      ],
    );
  }

  /// Текст последней неудавшейся записи этапа — экран показывает его цеху.
  ///
  /// Раньше сбой записи виден не был вообще: `catch { debugPrint }` в каждом
  /// методе, оптимистичное локальное обновление поверх — и оператор был
  /// уверен, что действие сохранилось.
  String? _lastStageWriteError;
  String? get lastStageWriteError => _lastStageWriteError;

  void clearStageWriteError() {
    if (_lastStageWriteError == null) return;
    _lastStageWriteError = null;
  }

  /// Единственный способ менять состав исполнителей и историю этапа.
  ///
  /// Весь список операций уходит одним вызовом и применяется сервером в одной
  /// транзакции — целиком либо никак. Прежняя цепочка независимых запросов на
  /// цеховой сети оставляла действие наполовину выполненным: пересмену без
  /// записи `shift_pause`, старт без строки в `assignees`.
  ///
  /// Возвращает false, если запись не удалась; локальное состояние при этом не
  /// трогается. Расхождение «на экране назначен, в базе нет» и запирало
  /// рабочее место: без назначения экран не показывал сотруднику кнопок, а
  /// незакрытый интервал запрещал старт.
  /// Пропавшая связь больше не теряет действие: [_stageOutbox] дошлёт его сам.
  Future<bool> applyStageEvents({
    required String taskId,
    required List<Map<String, dynamic>> ops,
    String? expectAssignee,
    String? label,
  }) async {
    if (ops.isEmpty) return true;
    final expect = (expectAssignee != null && expectAssignee.trim().isNotEmpty)
        ? expectAssignee.trim()
        : null;
    await _ensureStageOutboxLoaded();

    // Ключ создаётся на НАМЕРЕНИЕ. Если такое же намерение уже лежит в
    // очереди — оператор нажал кнопку второй раз, не дождавшись связи, — берём
    // его ключ: сервер узнает повтор и не задвоит запись.
    final draft = StageEventRequest(
      requestId: '',
      taskId: taskId,
      ops: ops,
      expectAssignee: expect,
      createdAtMillis: DateTime.now().millisecondsSinceEpoch,
      label: label,
    );
    final request = StageEventRequest(
      requestId: _stageOutbox.pendingIdFor(draft) ?? const Uuid().v4(),
      taskId: taskId,
      ops: ops,
      expectAssignee: expect,
      createdAtMillis: draft.createdAtMillis,
      label: label,
    );

    final result = await _sendStageEvents(request);
    switch (result.outcome) {
      case StageSendOutcome.applied:
        _mergeStageEventsResult(taskId, result.payload);
        _lastStageWriteError = null;
        return true;
      case StageSendOutcome.rejected:
        _lastStageWriteError = result.error;
        return false;
      case StageSendOutcome.retry:
        // Связь оборвалась. Намерение остаётся в очереди и уйдёт само, поэтому
        // цеху говорим именно это, а не «повторите»: повторное нажатие тут
        // ничего не ускорит.
        await _stageOutbox.enqueue(
          request,
          nowMillis: DateTime.now().millisecondsSinceEpoch,
        );
        _scheduleStageOutboxFlush();
        _lastStageWriteError =
            'Нет связи с сервером. Действие сохранено на планшете и '
            'отправится само, как только связь появится '
            '(в очереди: ${_stageOutbox.pendingCount}). Повторять не нужно.';
        return false;
    }
  }

  /// Одна попытка отправки. Разделяет обрыв связи и отказ сервера: первое
  /// повторяется, второе — нет.
  Future<StageSendResult> _sendStageEvents(StageEventRequest request) async {
    try {
      await _ensureAuthed();
      final result = await _supabase.rpc(
        'task_apply_stage_events',
        params: {
          'p_task_id': request.taskId,
          'p_ops': request.ops,
          if (request.expectAssignee != null)
            'p_expect_assignee': request.expectAssignee,
          'p_request_id': request.requestId,
        },
      );
      return StageSendResult.applied(result);
    } catch (e, st) {
      debugPrint('❌ task_apply_stage_events error: $e\n$st');
      if (isTransientNetworkFailure(e)) {
        return StageSendResult.retry(describeStageWriteFailure(e));
      }
      return StageSendResult.rejected(describeStageWriteFailure(e));
    }
  }

  // ---- Очередь повторов -----------------------------------------------------

  late final StageEventOutbox _stageOutbox = StageEventOutbox(
    sender: _sendStageEvents,
    store: _PrefsStageOutboxStore(),
    onApplied: (request, payload) {
      // Сервер посчитал состояние — показываем его, иначе экран остался бы с
      // тем, что было до потерянного действия.
      _mergeStageEventsResult(request.taskId, payload);
    },
    onRejected: (request, reason) {
      _lastStageWriteError = reason;
      if (!_disposed) notifyListeners();
    },
    onChanged: () {
      if (!_disposed) notifyListeners();
    },
  );

  Timer? _stageOutboxTimer;
  Future<void>? _stageOutboxLoad;

  /// Сколько действий ждёт связи. Экран показывает это цеху.
  int get pendingStageWrites => _stageOutbox.pendingCount;

  Future<void> _ensureStageOutboxLoaded() {
    return _stageOutboxLoad ??= _stageOutbox.load().then((_) {
      // Планшет выключили с непустой очередью — досылаем при первом же
      // действии после запуска.
      if (_stageOutbox.pendingCount > 0) _scheduleStageOutboxFlush();
    });
  }

  /// Досылает очередь. Вызывается по таймеру и вручную при обновлении списка.
  Future<void> flushStageOutbox() async {
    if (_disposed) return;
    await _ensureStageOutboxLoaded();
    if (_stageOutbox.pendingCount == 0) {
      _stageOutboxTimer?.cancel();
      _stageOutboxTimer = null;
      return;
    }
    await _stageOutbox.flush(
      nowMillis: DateTime.now().millisecondsSinceEpoch,
    );
    if (_stageOutbox.pendingCount == 0) {
      _stageOutboxTimer?.cancel();
      _stageOutboxTimer = null;
    } else {
      _scheduleStageOutboxFlush();
    }
  }

  /// Один таймер на очередь, пока в ней что-то есть.
  ///
  /// Период короче самой короткой выдержки: сама очередь решает, чему уже
  /// пришёл срок, а таймер лишь регулярно её будит.
  void _scheduleStageOutboxFlush() {
    if (_disposed) return;
    _stageOutboxTimer ??= Timer.periodic(
      const Duration(seconds: 5),
      (_) => unawaited(flushStageOutbox()),
    );
  }

  /// Ответ RPC — уже посчитанные сервером assignees и comments. Берём их, а не
  /// пересобираем локально: так экран показывает ровно то, что в базе.
  void _mergeStageEventsResult(String taskId, dynamic result) {
    if (result is! Map) return;
    final idx = _tasks.indexWhere((t) => t.id == taskId);
    if (idx == -1) return;
    final current = _tasks[idx];
    _setTask(
      idx,
      current.copyWith(
        assignees: assigneesFromRaw(result['assignees']),
        comments: _toTaskComments(_normalizeComments(result['comments'])),
      ),
    );
    notifyListeners();
  }

  /// Добавляет исполнителя атомарно, на сервере.
  ///
  /// Прежний код собирал новый массив из снимка задачи в build и перезаписывал
  /// `assignees` целиком. Два сотрудника, нажавшие «Начать» в пределах одного
  /// сетевого round-trip, затирали друг друга: чей PATCH долетал последним,
  /// тот и оставался единственным исполнителем.
  Future<bool> addAssignee(String id, String userId) => applyStageEvents(
        taskId: id,
        ops: [StageEventOps.addAssignee(userId)],
      );

  Future<bool> removeAssignee(String id, String userId) => applyStageEvents(
        taskId: id,
        ops: [StageEventOps.removeAssignee(userId)],
      );

  Future<bool> assignToUser(String taskId, String userId) =>
      addAssignee(taskId, userId);

  Future<void> createTask({
    required String orderId,
    required String stageId,
    String? stageGroupKey,
  }) async {
    try {
      await _supabase.from('tasks').insert({
        'order_id': orderId,
        'stage_id': stageId,
        'stage_group_key':
            (stageGroupKey == null || stageGroupKey.trim().isEmpty)
                ? stageId
                : stageGroupKey.trim(),
        'status': 'waiting',
        'assignees': [],
        'comments': [],
      });
      await refresh();
    } catch (e, st) {
      debugPrint('❌ createTask error: $e\n$st');
    }
  }

  /// Приводит состав исполнителей к заданному списку.
  ///
  /// Осталась ровно для одного случая — правки состава техлидом, когда нужен
  /// именно указанный список. Рабочие сценарии цеха («начать», «присоединить
  /// помощника», «снять помощника», «пересмена») ходят через
  /// [addAssignee]/[removeAssignee]: слепая перезапись всего массива теряла
  /// сотрудников, которых добавил соседний планшет.
  Future<bool> updateAssignees(String id, List<String> assignees) async {
    final index = _tasks.indexWhere((t) => t.id == id);
    final current = index == -1 ? const <String>[] : _tasks[index].assignees;
    final ops = <Map<String, dynamic>>[
      for (final userId in current)
        if (!assignees.contains(userId)) StageEventOps.removeAssignee(userId),
      for (final userId in assignees) StageEventOps.addAssignee(userId),
    ];
    return applyStageEvents(taskId: id, ops: ops);
  }

  Future<void> _maybeUpdateActualQtyAfterStage(
      String orderId, String stageId) async {
    await recomputeOrderActualQty(orderId, completedStageId: stageId);
  }

  /// Что известно после правки количества — нужно смежным действиям
  /// (претензии сотрудникам, сообщение в чат).
  ///
  /// [summary] — человеческая формулировка «было → стало» с причиной; она же
  /// уходит и в историю заказа, и в описание претензии, чтобы сотрудник видел
  /// ровно тот текст, что и техлид.

  /// Исправляет зафиксированное количество: техлид правит число, которое
  /// сотрудник ввёл неверно.
  ///
  /// Одним действием закрывает все три места, где это число живёт:
  ///  * запись в `tasks.comments` — из неё же считается аналитика сотрудника
  ///    и его сдельная часть, отдельного хранилища у аналитики нет;
  ///  * след в истории заказа — отдельный комментарий `quantity_edit`
  ///    с прежним значением, новым и причиной;
  ///  * `orders.actual_qty` — через [recomputeOrderActualQty], который сам
  ///    решает, формирует ли этот этап фактическое количество (правило
  ///    «после упаковки», последний этап). Если не формирует — факт не
  ///    тронется, и это верно.
  ///
  /// Пишет через RPC `update_task_quantity_comment`: комментарии лежат одним
  /// jsonb в строке задачи, и клиентский «прочитал всё → записал всё» затёр бы
  /// комментарии, которые сотрудник успел записать между чтением и записью.
  ///
  /// Бросает исключение с человеческим текстом — вызывающий показывает его.
  Future<QuantityEditResult> editQuantityRecord({
    required String taskId,
    required String commentId,
    required double newActual,
    required String reason,
    required String editorUserId,
    required String editorName,
  }) async {
    if (newActual < 0) {
      throw Exception('Количество не может быть отрицательным.');
    }
    final trimmedReason = reason.trim();
    if (trimmedReason.isEmpty) {
      throw Exception('Укажите причину правки.');
    }

    // Читаем запись заново: техлид мог открыть аналитику давно, а число за
    // это время исправил кто-то другой. Пересобирать payload нужно от того,
    // что лежит в базе сейчас.
    final row = await _supabase
        .from('tasks')
        .select('comments, order_id, stage_id')
        .eq('id', taskId)
        .maybeSingle();
    if (row == null) {
      throw Exception('Задание не найдено — обновите аналитику.');
    }

    Map<String, dynamic>? target;
    for (final c in _rowComments(Map<String, dynamic>.from(row))) {
      if ((c['id'] ?? '').toString() == commentId) {
        target = c;
        break;
      }
    }
    if (target == null) {
      throw Exception(
        'Запись количества не найдена — возможно, её уже исправили. '
        'Обновите аналитику.',
      );
    }

    final previousText = (target['text'] ?? '').toString();
    final previousActual = quantityActualFromText(previousText) ?? 0;
    final previousDisplay = quantityDisplayText(previousText);
    final newText = rebuildQuantityPayload(
      previousText: previousText,
      newActual: newActual,
      editorId: editorUserId,
      editedAt: DateTime.now(),
    );
    final newDisplay = quantityDisplayText(newText);

    if (previousActual == newActual) {
      throw Exception('Новое количество совпадает с прежним.');
    }

    final orderId = (row['order_id'] ?? '').toString();
    final stageId = (row['stage_id'] ?? '').toString();
    final summary = 'Количество исправлено: $previousDisplay → $newDisplay. '
        'Причина: $trimmedReason';
    final auditText = '$summary. Исправил: '
        '${editorName.trim().isEmpty ? editorUserId : editorName.trim()}';

    try {
      await _supabase.rpc('update_task_quantity_comment', params: {
        'p_task_id': taskId,
        'p_comment_id': commentId,
        'p_new_text': newText,
        'p_audit_text': auditText,
        'p_audit_user_id': editorUserId,
      });
    } on PostgrestException catch (e) {
      if ((e.code ?? '') == 'PGRST202' ||
          e.message.contains('update_task_quantity_comment')) {
        throw Exception(
          'На сервере нет функции правки количества. Примените миграцию '
          '20260818_edit_task_quantity_comment.sql.',
        );
      }
      throw Exception(e.message);
    }

    // Локальная правка вместо refresh(): полный select('*') по всем задачам
    // занимает десятки секунд (в логах он и вовсе отваливался по таймауту), а
    // окно правки всё это время висело. Нужное состояние известно и так —
    // патчим кэш на месте.
    _applyLocalQuantityEdit(
      taskId: taskId,
      commentId: commentId,
      newText: newText,
      auditText: auditText,
      editorUserId: editorUserId,
    );

    // Пересчёт факта заказа и аудит не задерживают закрытие окна: сама правка
    // уже записана, actual_qty — производная от неё. Ждать их нечего и по
    // другой причине: recomputeOrderActualQty гасит свои ошибки внутри, так
    // что await не дал бы ни одного дополнительного сигнала.
    if (orderId.isNotEmpty) {
      unawaited(recomputeOrderActualQty(orderId, completedStageId: stageId));
    }

    unawaited(AuditLogService().logEvent(
      userId: editorUserId,
      action: 'quantity_edit',
      orderId: orderId,
      stageId: stageId,
      category: 'analytics',
      details: auditText,
    ));

    return QuantityEditResult(
      taskId: taskId,
      commentId: commentId,
      orderId: orderId,
      stageId: stageId,
      summary: summary,
    );
  }

  /// Отражает правку количества в локальном кэше задач — ровно то, что сделал
  /// на сервере `update_task_quantity_comment`.
  void _applyLocalQuantityEdit({
    required String taskId,
    required String commentId,
    required String newText,
    required String auditText,
    required String editorUserId,
  }) {
    final idx = _tasks.indexWhere((t) => t.id == taskId);
    if (idx == -1) return;
    final current = _tasks[idx];
    final updated = <TaskComment>[
      for (final c in current.comments)
        if (c.id == commentId)
          TaskComment(
            id: c.id,
            type: c.type,
            text: newText,
            userId: c.userId,
            timestamp: c.timestamp,
          )
        else
          c,
    ];
    if (auditText.trim().isNotEmpty) {
      final now = DateTime.now().millisecondsSinceEpoch;
      updated.add(TaskComment(
        id: 'local-$now',
        type: 'quantity_edit',
        text: auditText,
        userId: editorUserId,
        timestamp: now,
      ));
    }
    updated.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    _setTask(idx, current.copyWith(comments: updated));
    notifyListeners();
  }

  /// Пересчитывает orders.actual_qty.
  ///
  /// Считает СЕРВЕР (`recompute_order_actual_qty`), клиент только просит.
  /// Раньше факт писали трое по разным правилам: этот метод (правило «после
  /// упаковки»), `advance_order_after_task_completion` (сумма последнего
  /// закрытого этапа) и сохранение заказа своим снимком. Побеждал последний:
  /// у заказа Agosto упаковка сделала 3100 шт, а сервер, закрыв следом этап
  /// ручек без количества, затёр факт нулём. Правило перенесено на сервер
  /// один в один, а запись actual_qty в обход функции база теперь игнорирует
  /// (триггер `orders_guard_actual_qty`).
  ///
  /// Сервер и сам пересчитывает факт при каждом завершении этапа. Вызов
  /// отсюда нужен путям, которые меняют количество без завершения: правка
  /// записи техлидом, возобновление этапа.
  Future<void> recomputeOrderActualQty(String orderId,
      {String? completedStageId}) async {
    if (orderId.trim().isEmpty) return;
    try {
      await _supabase.rpc('recompute_order_actual_qty', params: {
        'p_order_id': orderId,
        'p_completed_stage_id': completedStageId,
      });
      RealtimeSyncService.instance.invalidateLocal(RealtimeResource.orders);
    } catch (e, st) {
      debugPrint('❌ recomputeOrderActualQty error: $e\n$st');
    }
  }

  List<Map<String, dynamic>> _rowComments(Map<String, dynamic> row) {
    final c = row['comments'];
    final comments = <Map<String, dynamic>>[];
    if (c is List) {
      comments
          .addAll(c.whereType<Map>().map((e) => Map<String, dynamic>.from(e)));
    } else if (c is Map) {
      c.forEach((_, v) {
        if (v is Map) comments.add(Map<String, dynamic>.from(v));
      });
    }
    return comments;
  }

  @override
  void dispose() {
    _disposed = true;
    _fallbackPollTimer?.cancel();
    _fallbackPollTimer = null;
    _stageOutboxTimer?.cancel();
    _stageOutboxTimer = null;
    RealtimeSyncService.instance.unregisterOwner(this);
    super.dispose();
  }

  /// Добавляет комментарий, автоматически подставляя текущего пользователя из Supabase Auth.
  Future<bool> addCommentAutoUser({
    required String taskId,
    required String type,
    required String text,
    String? userIdOverride,
  }) async {
    try {
      await _ensureAuthed();
    } catch (e, st) {
      // Обновление токена идёт по сети и на цеховом Wi-Fi падает. Раньше
      // исключение отсюда вылетало из всего обработчика, и остаток действия
      // (например записи пересмены) просто не выполнялся.
      _lastStageWriteError = describeStageWriteFailure(e);
      debugPrint('❌ addCommentAutoUser auth error: $e\n$st');
      return false;
    }
    final uid = (userIdOverride != null && userIdOverride.isNotEmpty)
        ? userIdOverride
        : _supabase.auth.currentUser?.id;
    if (uid == null || uid.isEmpty) {
      _lastStageWriteError = 'Не удалось определить сотрудника для записи.';
      debugPrint('❌ addCommentAutoUser: нет авторизованного пользователя');
      return false;
    }
    return addComment(taskId: taskId, type: type, text: text, userId: uid);
  }
}
