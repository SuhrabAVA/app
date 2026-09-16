import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../utils/auth_helper.dart';

/// Области состояния, которые могут быть точечно перечитаны после события БД.
enum RealtimeResource {
  orders,
  tasks,
  taskAttachments,
  productionQueueLegacy,
  productionQueuePositions,
  templates,
  personnelEmployees,
  personnelPositions,
  personnelWorkplaces,
  personnelTerminals,
  personnelStatuses,
  warehousePaints,
  warehouseMaterials,
  warehousePapers,
  warehousePens,
  warehouseStationery,
  warehousePaperReservations,
  warehousePaintReservations,
  warehouseCategoryList,
  warehouseCategoryItems,
  warehouseDeletedRecords,
  forms,
  suppliers,
  productTypeSettings,
  analytics,
  chat,
}

typedef RealtimeRefreshHandler = Future<void> Function();

@immutable
class RealtimeInvalidation {
  const RealtimeInvalidation({
    required this.schema,
    required this.table,
    required this.event,
    required this.resources,
  });

  final String schema;
  final String table;
  final PostgresChangeEvent event;
  final Set<RealtimeResource> resources;
}

@immutable
class _RealtimeTableRoute {
  const _RealtimeTableRoute(
    this.table,
    this.resources, {
    this.schema = 'public',
  });

  final String schema;
  final String table;
  final Set<RealtimeResource> resources;

  String get qualifiedName => '$schema.$table';
}

/// Небольшой тестируемый планировщик: burst событий превращается в один
/// refresh, а событие во время выполняющегося refresh — максимум в один
/// дополнительный проход.
class RealtimeRefreshScheduler {
  RealtimeRefreshScheduler({
    required this.handler,
    this.debounce = const Duration(milliseconds: 250),
    this.onCoalesced,
  });

  final RealtimeRefreshHandler handler;
  final Duration debounce;
  final VoidCallback? onCoalesced;

  Timer? _timer;
  Future<void>? _running;
  bool _queued = false;
  bool _disposed = false;

  bool get isScheduled => _timer != null;
  bool get isRefreshing => _running != null;
  Future<void> get settled => _running ?? Future<void>.value();

  void schedule() {
    if (_disposed) return;
    if (_timer != null || _running != null) onCoalesced?.call();
    _timer?.cancel();
    _timer = Timer(debounce, () {
      _timer = null;
      unawaited(refreshNow());
    });
  }

  Future<void> refreshNow() {
    if (_disposed) return Future<void>.value();
    _timer?.cancel();
    _timer = null;
    final running = _running;
    if (running != null) {
      _queued = true;
      onCoalesced?.call();
      return running;
    }

    final future = _drain();
    _running = future;
    return future.whenComplete(() {
      if (identical(_running, future)) _running = null;
    });
  }

  Future<void> _drain() async {
    do {
      _queued = false;
      await handler();
    } while (_queued && !_disposed);
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    _queued = false;
  }
}

/// Generation guard shared by channel callbacks and reconnect timers.
/// A callback created for an earlier logical session or channel instance is
/// rejected even if the Supabase client delivers it after removeChannel().
class RealtimeGenerationGate {
  int _sessionGeneration = 0;
  final Map<String, int> _channelGenerations = <String, int>{};

  int get sessionGeneration => _sessionGeneration;
  Map<String, int> get channelGenerations =>
      Map<String, int>.unmodifiable(_channelGenerations);

  int nextSession() => ++_sessionGeneration;

  int nextChannel(String domain) {
    final generation = (_channelGenerations[domain] ?? 0) + 1;
    _channelGenerations[domain] = generation;
    return generation;
  }

  bool accepts({
    required String domain,
    required int channelGeneration,
    required int sessionGeneration,
  }) {
    return _sessionGeneration == sessionGeneration &&
        _channelGenerations[domain] == channelGeneration;
  }
}

/// Owns reconnect timers and guarantees at most one pending timer per domain.
class RealtimeReconnectScheduler {
  final Map<String, Timer> _timers = <String, Timer>{};

  int get pendingCount => _timers.length;
  Set<String> get pendingDomains => Set<String>.unmodifiable(_timers.keys);

  bool schedule({
    required String domain,
    required Duration delay,
    required bool Function() isCurrent,
    required VoidCallback reconnect,
  }) {
    if (_timers.containsKey(domain)) return false;
    _timers[domain] = Timer(delay, () {
      _timers.remove(domain);
      if (isCurrent()) reconnect();
    });
    return true;
  }

  void cancel(String domain) => _timers.remove(domain)?.cancel();

  void cancelAll() {
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
  }
}

@immutable
class RealtimeSyncDiagnostics {
  const RealtimeSyncDiagnostics({
    required this.started,
    required this.logicalSessionActive,
    required this.supabaseSessionActive,
    required this.sessionGeneration,
    required this.channelCount,
    required this.channelStatuses,
    required this.channelGenerations,
    required this.declaredDomainCount,
    required this.declaredTableCount,
    required this.publishedTableCount,
    required this.handlerCounts,
    required this.handlerOwners,
    required this.scheduledRefreshCount,
    required this.runningRefreshCount,
    required this.reconnectTimerCount,
  });

  final bool started;
  final bool logicalSessionActive;
  final bool supabaseSessionActive;
  final int sessionGeneration;
  final int channelCount;
  final Map<String, String> channelStatuses;
  final Map<String, int> channelGenerations;
  final int declaredDomainCount;
  final int declaredTableCount;
  final int? publishedTableCount;
  final Map<String, int> handlerCounts;
  final Map<String, List<String>> handlerOwners;
  final int scheduledRefreshCount;
  final int runningRefreshCount;
  final int reconnectTimerCount;

  @override
  String toString() => 'started=$started logical=$logicalSessionActive '
      'supabase=$supabaseSessionActive sessionGen=$sessionGeneration '
      'channels=$channelCount/$declaredDomainCount statuses=$channelStatuses '
      'channelGen=$channelGenerations tables=$declaredTableCount '
      'published=${publishedTableCount ?? 'unknown'} handlers=$handlerCounts '
      'owners=$handlerOwners '
      'scheduled=$scheduledRefreshCount running=$runningRefreshCount '
      'reconnectTimers=$reconnectTimerCount';
}

class _RegisteredRefreshHandler {
  const _RegisteredRefreshHandler(this.owner, this.handler);

  final Object owner;
  final RealtimeRefreshHandler handler;
}

/// Единственный владелец глобальных Supabase Realtime-каналов приложения.
///
/// Провайдеры регистрируют здесь уже существующие методы чтения. Сервис не
/// применяет payload к моделям и никогда не вызывает команды записи.
class RealtimeSyncService {
  RealtimeSyncService._();

  static final RealtimeSyncService instance = RealtimeSyncService._();

  static const Duration _refreshDebounce = Duration(milliseconds: 250);
  // Потолок backoff переподключения. На цеховом Wi-Fi сокет часто рвётся, и при
  // прежних 30с «мёртвое» окно доходило до 30 секунд — данные на других
  // планшетах подхватывались только по этому таймауту. 5с даёт быстрый повтор
  // без заметного трафика (переподписка — один лёгкий WS-хендшейк).
  static const Duration _maxReconnectDelay = Duration(seconds: 5);

  static const Map<String, List<_RealtimeTableRoute>> _routesByDomain = {
    'core': [
      _RealtimeTableRoute('orders', {
        RealtimeResource.orders,
        RealtimeResource.tasks,
      }),
      _RealtimeTableRoute('tasks', {
        RealtimeResource.tasks,
      }),
      _RealtimeTableRoute('task_comment_attachments', {
        RealtimeResource.taskAttachments,
      }),
      _RealtimeTableRoute('order_paper_reservations', {
        RealtimeResource.warehousePaperReservations,
      }),
      _RealtimeTableRoute('order_paint_reservations', {
        RealtimeResource.warehousePaintReservations,
      }),
    ],
    'planning': [
      _RealtimeTableRoute('prod_plans', {
        RealtimeResource.tasks,
      }),
      _RealtimeTableRoute('prod_plan_stages', {
        RealtimeResource.tasks,
      }),
      _RealtimeTableRoute('prod_stage_history', {
        RealtimeResource.analytics,
      }),
      _RealtimeTableRoute('production_plans', {
        RealtimeResource.tasks,
      }),
      _RealtimeTableRoute(
        'plan_stages',
        {RealtimeResource.tasks},
        schema: 'production',
      ),
      _RealtimeTableRoute('workplace_queue_positions', {
        RealtimeResource.productionQueuePositions,
      }),
      _RealtimeTableRoute('production_queue_state', {
        RealtimeResource.productionQueueLegacy,
      }),
      _RealtimeTableRoute('plan_templates', {
        RealtimeResource.templates,
        RealtimeResource.tasks,
      }),
      _RealtimeTableRoute('workplace_stages', {
        RealtimeResource.tasks,
      }),
      _RealtimeTableRoute('order_stages', {
        RealtimeResource.tasks,
      }),
    ],
    'personnel': [
      _RealtimeTableRoute('employees', {
        RealtimeResource.personnelEmployees,
        RealtimeResource.chat,
      }),
      _RealtimeTableRoute('employee_positions', {
        RealtimeResource.personnelEmployees,
      }),
      _RealtimeTableRoute('positions', {
        RealtimeResource.personnelPositions,
        RealtimeResource.personnelEmployees,
      }),
      _RealtimeTableRoute('workplaces', {
        RealtimeResource.personnelWorkplaces,
        RealtimeResource.productTypeSettings,
      }),
      _RealtimeTableRoute('workplace_positions', {
        RealtimeResource.personnelWorkplaces,
      }),
      _RealtimeTableRoute('terminals', {
        RealtimeResource.personnelTerminals,
      }),
      _RealtimeTableRoute('terminal_workplaces', {
        RealtimeResource.personnelTerminals,
      }),
      _RealtimeTableRoute('employee_statuses', {
        RealtimeResource.personnelStatuses,
      }),
      _RealtimeTableRoute('employee_status_history', {
        RealtimeResource.personnelStatuses,
      }),
      _RealtimeTableRoute('employee_photos', {
        RealtimeResource.personnelEmployees,
      }),
      _RealtimeTableRoute('documents', {
        RealtimeResource.chat,
      }),
    ],
    'warehouse_config': [
      _RealtimeTableRoute('paints', {RealtimeResource.warehousePaints}),
      _RealtimeTableRoute(
        'materials',
        {RealtimeResource.warehouseMaterials},
      ),
      _RealtimeTableRoute('papers', {RealtimeResource.warehousePapers}),
      _RealtimeTableRoute('warehouse_pens', {RealtimeResource.warehousePens}),
      _RealtimeTableRoute(
        'warehouse_stationery',
        {
          RealtimeResource.warehouseStationery,
          RealtimeResource.warehousePens,
        },
      ),
      // Журналы доставляются также экранным in-memory listeners. Пустой
      // resource set не запускает тяжёлый fetchTmc: изменение базового остатка
      // приходит отдельным событием соответствующей таблицы.
      _RealtimeTableRoute('paints_arrivals', <RealtimeResource>{}),
      _RealtimeTableRoute('materials_arrivals', <RealtimeResource>{}),
      _RealtimeTableRoute('papers_arrivals', <RealtimeResource>{}),
      _RealtimeTableRoute(
        'warehouse_stationery_arrivals',
        <RealtimeResource>{},
      ),
      _RealtimeTableRoute('warehouse_pens_arrivals', <RealtimeResource>{}),
      _RealtimeTableRoute('paints_writeoffs', <RealtimeResource>{}),
      _RealtimeTableRoute('materials_writeoffs', <RealtimeResource>{}),
      _RealtimeTableRoute('papers_writeoffs', <RealtimeResource>{}),
      _RealtimeTableRoute(
        'warehouse_stationery_writeoffs',
        <RealtimeResource>{},
      ),
      _RealtimeTableRoute('warehouse_pens_writeoffs', <RealtimeResource>{}),
      _RealtimeTableRoute('paints_inventories', <RealtimeResource>{}),
      _RealtimeTableRoute('materials_inventories', <RealtimeResource>{}),
      _RealtimeTableRoute('papers_inventories', <RealtimeResource>{}),
      _RealtimeTableRoute(
        'warehouse_stationery_inventories',
        <RealtimeResource>{},
      ),
      _RealtimeTableRoute(
        'warehouse_pens_inventories',
        <RealtimeResource>{},
      ),
      _RealtimeTableRoute('suppliers', {RealtimeResource.suppliers}),
      _RealtimeTableRoute('warehouse_categories', {
        RealtimeResource.productTypeSettings,
        RealtimeResource.warehouseCategoryList,
      }),
      _RealtimeTableRoute('warehouse_category_items', {
        RealtimeResource.warehouseCategoryItems,
      }),
      _RealtimeTableRoute('warehouse_category_writeoffs', {
        RealtimeResource.warehouseCategoryItems,
      }),
      _RealtimeTableRoute('warehouse_category_inventories', {
        RealtimeResource.warehouseCategoryItems,
      }),
      _RealtimeTableRoute('warehouse_deleted_records', {
        RealtimeResource.warehouseDeletedRecords,
      }),
      _RealtimeTableRoute('forms', {RealtimeResource.forms}),
      _RealtimeTableRoute('forms_series', {RealtimeResource.forms}),
      _RealtimeTableRoute('order_form_blocks', {
        RealtimeResource.productTypeSettings,
      }),
      _RealtimeTableRoute('product_type_configs', {
        RealtimeResource.productTypeSettings,
      }),
      _RealtimeTableRoute('product_type_form_blocks', {
        RealtimeResource.productTypeSettings,
      }),
      _RealtimeTableRoute('product_type_stages', {
        RealtimeResource.productTypeSettings,
      }),
      _RealtimeTableRoute('product_type_stage_workplaces', {
        RealtimeResource.productTypeSettings,
      }),
      _RealtimeTableRoute('product_type_stage_conditions', {
        RealtimeResource.productTypeSettings,
      }),
    ],
    'analytics': [
      _RealtimeTableRoute('claims', {RealtimeResource.analytics}),
      _RealtimeTableRoute('employee_month_salary_adjustments', {
        RealtimeResource.analytics,
      }),
      _RealtimeTableRoute('employee_status_pay_rates', {
        RealtimeResource.analytics,
      }),
      _RealtimeTableRoute('salary_settings', {RealtimeResource.analytics}),
      _RealtimeTableRoute('work_schedules', {RealtimeResource.analytics}),
      _RealtimeTableRoute('workplace_coefficients', {
        RealtimeResource.analytics,
      }),
    ],
  };

  SupabaseClient get _client => Supabase.instance.client;

  final Map<RealtimeResource, List<_RegisteredRefreshHandler>> _handlers = {};
  final Map<RealtimeResource, RealtimeRefreshScheduler> _schedulers = {};
  final Map<String, RealtimeChannel> _channels = {};
  final Map<String, String> _channelStatuses = <String, String>{};
  final Map<String, int> _reconnectAttempts = {};
  final Set<String> _subscribedOnce = {};
  final RealtimeGenerationGate _generationGate = RealtimeGenerationGate();
  final RealtimeReconnectScheduler _reconnectScheduler =
      RealtimeReconnectScheduler();
  final StreamController<RealtimeInvalidation> _events =
      StreamController<RealtimeInvalidation>.broadcast();

  StreamSubscription<AuthState>? _authSubscription;
  Future<void>? _channelMutation;
  bool _channelMutationQueued = false;
  bool _started = false;
  bool _stopping = false;
  bool _logicalSessionActive = false;
  bool _supabaseSessionActive = false;
  bool _inBackground = false;
  Set<String>? _publishedTables;
  Future<void> _sessionRefreshDrain = Future<void>.value();

  Stream<RealtimeInvalidation> get events => _events.stream;

  int get channelCount => _channels.length;

  @visibleForTesting
  static int get debugDeclaredDomainCount => _routesByDomain.length;

  @visibleForTesting
  static Set<String> get debugDeclaredTables => <String>{
        for (final routes in _routesByDomain.values)
          for (final route in routes) route.qualifiedName,
      };

  @visibleForTesting
  static Set<RealtimeResource> debugResourcesForTable(
    String table, {
    String schema = 'public',
  }) =>
      <RealtimeResource>{
        for (final routes in _routesByDomain.values)
          for (final route in routes)
            if (route.table == table && route.schema == schema)
              ...route.resources,
      };

  RealtimeSyncDiagnostics get diagnostics => RealtimeSyncDiagnostics(
        started: _started,
        logicalSessionActive: _logicalSessionActive,
        supabaseSessionActive: _supabaseSessionActive,
        sessionGeneration: _generationGate.sessionGeneration,
        channelCount: _channels.length,
        channelStatuses: Map<String, String>.unmodifiable(_channelStatuses),
        channelGenerations: _generationGate.channelGenerations,
        declaredDomainCount: _routesByDomain.length,
        declaredTableCount: debugDeclaredTables.length,
        publishedTableCount: _publishedTables?.length,
        handlerCounts: <String, int>{
          for (final entry in _handlers.entries)
            entry.key.name: entry.value.length,
        },
        handlerOwners: <String, List<String>>{
          for (final entry in _handlers.entries)
            entry.key.name: <String>[
              for (final handler in entry.value)
                handler.owner.runtimeType.toString(),
            ],
        },
        scheduledRefreshCount: _schedulers.values
            .where((scheduler) => scheduler.isScheduled)
            .length,
        runningRefreshCount: _schedulers.values
            .where((scheduler) => scheduler.isRefreshing)
            .length,
        reconnectTimerCount: _reconnectScheduler.pendingCount,
      );

  void registerRefreshHandler({
    required Object owner,
    required RealtimeResource resource,
    required RealtimeRefreshHandler handler,
  }) {
    final handlers = _handlers.putIfAbsent(resource, () => []);
    handlers.removeWhere((entry) => identical(entry.owner, owner));
    handlers.add(_RegisteredRefreshHandler(owner, handler));
    _ensureScheduler(resource);
  }

  void unregisterOwner(Object owner) {
    final emptyResources = <RealtimeResource>[];
    for (final entry in _handlers.entries) {
      entry.value.removeWhere((handler) => identical(handler.owner, owner));
      if (entry.value.isEmpty) emptyResources.add(entry.key);
    }
    for (final resource in emptyResources) {
      _handlers.remove(resource);
      _schedulers.remove(resource)?.dispose();
    }
  }

  Future<void> start() async {
    if (_started) return;
    _started = true;
    _stopping = false;
    _logicalSessionActive = AuthHelper.currentUserId != null;
    _supabaseSessionActive = _client.auth.currentSession != null;
    _chainResourceSchedulerReset();
    AuthHelper.sessionRevision.addListener(_onLogicalSessionChanged);
    _authSubscription = _client.auth.onAuthStateChange.listen(_onAuthState);
    if (!_canOwnChannels) {
      _log('startup suspended: logical=$_logicalSessionActive '
          'supabase=$_supabaseSessionActive');
      return;
    }
    await _loadPublishedTables();
    await _replaceChannels(reason: 'startup');
  }

  Future<void> stop() async {
    if (!_started) return;
    _stopping = true;
    _started = false;
    AuthHelper.sessionRevision.removeListener(_onLogicalSessionChanged);
    await _authSubscription?.cancel();
    _authSubscription = null;
    _advanceSessionGeneration();
    _chainResourceSchedulerReset();
    await _removeChannels();
    _stopping = false;
  }

  void handleLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      final wasInBackground = _inBackground;
      _inBackground = false;
      if (wasInBackground) {
        _log('foreground: reconnect and refresh active resources');
        unawaited(_replaceChannels(reason: 'foreground'));
        if (_canOwnChannels) unawaited(refreshRegisteredResources());
      }
      return;
    }
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached ||
        state == AppLifecycleState.hidden) {
      _inBackground = true;
      _log('background state=${state.name}');
    }
  }

  /// Локальная инвалидация ресурса — то же, что событие БД, но без сети.
  ///
  /// Нужна там, где один модуль пишет в чужую таблицу: завершение задания
  /// меняет `orders.status`, но своё же устройство узнавало об этом только
  /// из эха realtime. На слабой связи эхо приходит с задержкой в минуту,
  /// а при неопубликованной таблице не приходит вовсе — и заказ висел
  /// незавершённым на экране того, кто его только что закрыл.
  ///
  /// Проходит через тот же планировщик, что и события БД: burst правок
  /// схлопывается в один перечит.
  void invalidateLocal(RealtimeResource resource) {
    _schedulers[resource]?.schedule();
  }

  Future<void> refreshRegisteredResources() async {
    if (!_canOwnChannels) return;
    await _sessionRefreshDrain;
    final resources = _handlers.keys.toList(growable: false);
    await Future.wait(
      resources.map((resource) => _schedulers[resource]!.refreshNow()),
    );
  }

  void _onLogicalSessionChanged() {
    if (!_started) return;
    _logicalSessionActive = AuthHelper.currentUserId != null;
    _advanceSessionGeneration();
    _chainResourceSchedulerReset();
    _log('logical session changed: active=$_logicalSessionActive');
    unawaited(
      _restartAfterLogicalSession(_generationGate.sessionGeneration),
    );
  }

  void _onAuthState(AuthState state) {
    if (!_started) return;
    final event = state.event.name;
    if (event == 'signedOut') {
      _log('auth signed out: remove subscriptions');
      _supabaseSessionActive = false;
      _advanceSessionGeneration();
      _chainResourceSchedulerReset();
      unawaited(_replaceChannels(reason: 'auth-signedOut'));
      return;
    }
    if (event == 'tokenRefreshed' || event == 'userUpdated') {
      if (state.session == null) {
        _log('auth $event without session: remove subscriptions');
        _supabaseSessionActive = false;
        _advanceSessionGeneration();
        _chainResourceSchedulerReset();
        unawaited(_replaceChannels(reason: 'auth-$event-no-session'));
      } else {
        _supabaseSessionActive = true;
        _log('auth $event: keep subscriptions');
      }
      return;
    }
    if (event == 'signedIn' || event == 'initialSession') {
      final wasActive = _supabaseSessionActive;
      _supabaseSessionActive = state.session != null;
      if (!wasActive && _supabaseSessionActive && _logicalSessionActive) {
        _log('auth $event: resume subscriptions');
        unawaited(_resumeAfterAuth(event));
      }
    }
  }

  bool get _canOwnChannels =>
      _started && !_stopping && _logicalSessionActive && _supabaseSessionActive;

  void _advanceSessionGeneration() {
    _generationGate.nextSession();
    _reconnectScheduler.cancelAll();
    _reconnectAttempts.clear();
    _subscribedOnce.clear();
  }

  Future<void> _restartAfterLogicalSession(int sessionGeneration) async {
    await _replaceChannels(reason: 'logical-session');
    if (_canOwnChannels &&
        _generationGate.sessionGeneration == sessionGeneration) {
      await refreshRegisteredResources();
    }
  }

  Future<void> _resumeAfterAuth(String event) async {
    final sessionGeneration = _generationGate.sessionGeneration;
    if (_publishedTables == null) await _loadPublishedTables();
    if (_canOwnChannels &&
        _generationGate.sessionGeneration == sessionGeneration) {
      await _replaceChannels(reason: 'auth-$event');
      if (_canOwnChannels &&
          _generationGate.sessionGeneration == sessionGeneration) {
        await refreshRegisteredResources();
      }
    }
  }

  Future<void> _replaceChannels({required String reason}) {
    final running = _channelMutation;
    if (running != null) {
      _channelMutationQueued = true;
      return running;
    }
    final future = _runChannelMutation(reason);
    _channelMutation = future;
    return future.whenComplete(() {
      if (identical(_channelMutation, future)) _channelMutation = null;
    });
  }

  Future<void> _runChannelMutation(String reason) async {
    var nextReason = reason;
    do {
      _channelMutationQueued = false;
      await _removeChannels();
      await _sessionRefreshDrain;
      if (!_canOwnChannels) {
        nextReason = 'coalesced-restart';
        continue;
      }
      if (_publishedTables == null) await _loadPublishedTables();
      if (!_canOwnChannels) {
        nextReason = 'coalesced-restart';
        continue;
      }
      _log('create channels reason=$nextReason');
      _createChannels();
      nextReason = 'coalesced-restart';
    } while (_channelMutationQueued);
  }

  void _createChannels() {
    for (final domainEntry in _routesByDomain.entries) {
      final domain = domainEntry.key;
      final routes = domainEntry.value
          .where(
            (route) => _publishedTables?.contains(route.qualifiedName) ?? true,
          )
          .toList(growable: false);
      if (routes.isEmpty) {
        _log('channel skipped domain=$domain: no published tables');
        continue;
      }
      final generation = _generationGate.nextChannel(domain);
      final sessionGeneration = _generationGate.sessionGeneration;
      final channel = _client.channel('easy-pack:$domain:$generation');
      _log('channel created domain=$domain generation=$generation');
      for (final route in routes) {
        _log('listen ${route.schema}.${route.table} domain=$domain');
        channel.onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: route.schema,
          table: route.table,
          callback: (payload) => _onDatabaseChange(
            domain: domain,
            channelGeneration: generation,
            sessionGeneration: sessionGeneration,
            route: route,
            payload: payload,
          ),
        );
      }
      _channels[domain] = channel;
      channel.subscribe(
        (status, error) => _onSubscribeStatus(
          domain: domain,
          generation: generation,
          sessionGeneration: sessionGeneration,
          status: status,
          error: error,
        ),
      );
    }
    _log('diagnostics $diagnostics');
  }

  Future<void> _loadPublishedTables() async {
    try {
      final rows = await _client.rpc('realtime_sync_published_tables');
      if (rows is! List) return;
      _publishedTables = <String>{
        for (final row in rows.whereType<Map>())
          if ((row['table_name'] ?? '').toString().trim().isNotEmpty)
            '${(row['schema_name'] ?? 'public').toString().trim()}.'
                '${(row['table_name'] ?? '').toString().trim()}',
      };
      _log('publication discovered tables=${_publishedTables!.length}');
      for (final domain in _routesByDomain.values) {
        for (final route in domain) {
          if (!_publishedTables!.contains(route.qualifiedName)) {
            _log('listen skipped unpublished table=${route.qualifiedName}');
          }
        }
      }
    } catch (error) {
      // Backward-compatible startup before the migration is deployed. The
      // migration is still required for deterministic production operation.
      _publishedTables = null;
      _log('publication discovery unavailable; use declared routes: $error');
    }
  }

  Future<void> _removeChannels() async {
    _reconnectScheduler.cancelAll();
    final channels = _channels.values.toList(growable: false);
    _channels.clear();
    _channelStatuses.clear();
    for (final channel in channels) {
      try {
        await _client.removeChannel(channel);
      } catch (error) {
        _log('remove channel error=$error');
      }
    }
    _log('diagnostics $diagnostics');
  }

  void _onDatabaseChange(
      {required String domain,
      required int channelGeneration,
      required int sessionGeneration,
      required _RealtimeTableRoute route,
      required PostgresChangePayload payload}) {
    if (!_canOwnChannels ||
        !_channels.containsKey(domain) ||
        !_generationGate.accepts(
          domain: domain,
          channelGeneration: channelGeneration,
          sessionGeneration: sessionGeneration,
        )) {
      _log('stale event ignored ${route.qualifiedName} domain=$domain');
      return;
    }
    final invalidation = RealtimeInvalidation(
      schema: route.schema,
      table: route.table,
      event: payload.eventType,
      resources: route.resources,
    );
    _log(
      '${payload.eventType.name.toUpperCase()} '
      '${route.schema}.${route.table} invalidate='
      '${route.resources.map((resource) => resource.name).join(',')}',
    );
    _events.add(invalidation);
    for (final resource in route.resources) {
      _schedulers[resource]?.schedule();
    }
  }

  Future<void> _refreshResource(RealtimeResource resource) async {
    final sessionGeneration = _generationGate.sessionGeneration;
    final handlers = List<_RegisteredRefreshHandler>.from(
      _handlers[resource] ?? const <_RegisteredRefreshHandler>[],
    );
    if (handlers.isEmpty) return;
    _log('refresh resource=${resource.name} handlers=${handlers.length}');
    for (final registered in handlers) {
      if (_generationGate.sessionGeneration != sessionGeneration) {
        _log('refresh aborted stale session resource=${resource.name}');
        return;
      }
      try {
        await registered.handler();
      } catch (error, stackTrace) {
        _log('refresh error resource=${resource.name} error=$error');
        if (kDebugMode) debugPrintStack(stackTrace: stackTrace);
      }
    }
    _log('refresh complete resource=${resource.name}');
  }

  RealtimeRefreshScheduler _ensureScheduler(RealtimeResource resource) {
    return _schedulers.putIfAbsent(
      resource,
      () => RealtimeRefreshScheduler(
        debounce: _refreshDebounce,
        handler: () => _refreshResource(resource),
        onCoalesced: () => _log('refresh coalesced resource=${resource.name}'),
      ),
    );
  }

  Future<void> _resetResourceSchedulers() {
    final previous = _schedulers.values.toList(growable: false);
    _schedulers.clear();
    for (final scheduler in previous) {
      scheduler.dispose();
    }
    for (final resource in _handlers.keys) {
      _ensureScheduler(resource);
    }
    return Future.wait(previous.map((scheduler) => scheduler.settled));
  }

  void _chainResourceSchedulerReset() {
    final previousDrain = _sessionRefreshDrain;
    final currentDrain = _resetResourceSchedulers();
    _sessionRefreshDrain = Future.wait(<Future<void>>[
      previousDrain,
      currentDrain,
    ]);
  }

  @visibleForTesting
  Future<void> debugRefreshResource(RealtimeResource resource) =>
      _schedulers[resource]?.refreshNow() ?? Future<void>.value();

  void debugDumpDiagnostics() {
    if (kDebugMode) debugPrint('[REALTIME] diagnostics $diagnostics');
  }

  void _onSubscribeStatus({
    required String domain,
    required int generation,
    required int sessionGeneration,
    required RealtimeSubscribeStatus status,
    required Object? error,
  }) {
    if (!_canOwnChannels ||
        !_channels.containsKey(domain) ||
        !_generationGate.accepts(
          domain: domain,
          channelGeneration: generation,
          sessionGeneration: sessionGeneration,
        )) {
      return;
    }
    final statusName = status.name;
    _channelStatuses[domain] = statusName;
    if (statusName == 'subscribed') {
      final isReconnect = _subscribedOnce.contains(domain);
      _subscribedOnce.add(domain);
      _reconnectAttempts[domain] = 0;
      _reconnectScheduler.cancel(domain);
      _log('${isReconnect ? 'resubscribed' : 'subscribed'} domain=$domain');
      _log('diagnostics $diagnostics');
      return;
    }
    if (statusName == 'closed' ||
        statusName == 'channelError' ||
        statusName == 'timedOut') {
      _log('disconnected domain=$domain status=$statusName error=$error');
      _scheduleReconnect(domain, generation, sessionGeneration);
    }
  }

  void _scheduleReconnect(
    String domain,
    int generation,
    int sessionGeneration,
  ) {
    if (!_canOwnChannels) return;
    final attempt = (_reconnectAttempts[domain] ?? 0) + 1;
    _reconnectAttempts[domain] = attempt;
    final seconds = 1 << (attempt - 1).clamp(0, 5);
    final delay = Duration(seconds: seconds) > _maxReconnectDelay
        ? _maxReconnectDelay
        : Duration(seconds: seconds);
    _log('reconnect scheduled domain=$domain delay=${delay.inSeconds}s');
    _reconnectScheduler.schedule(
      domain: domain,
      delay: delay,
      isCurrent: () =>
          _canOwnChannels &&
          _channels.containsKey(domain) &&
          _generationGate.accepts(
            domain: domain,
            channelGeneration: generation,
            sessionGeneration: sessionGeneration,
          ),
      reconnect: () => unawaited(
        _replaceChannels(reason: 'reconnect-$domain'),
      ),
    );
  }

  void _log(String message) {
    if (kDebugMode) debugPrint('[REALTIME] $message');
  }
}
