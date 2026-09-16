import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sheet_clone/modules/production/production_queue_provider.dart';
import 'package:sheet_clone/services/realtime_sync_service.dart';

void main() {
  testWidgets('coalesces a burst into one refresh', (tester) async {
    var calls = 0;
    final scheduler = RealtimeRefreshScheduler(
      debounce: const Duration(milliseconds: 20),
      handler: () async => calls += 1,
    );

    for (var i = 0; i < 100; i += 1) {
      scheduler.schedule();
    }
    await tester.pump(const Duration(milliseconds: 10));
    scheduler.schedule();
    await tester.pump(const Duration(milliseconds: 19));
    expect(calls, 0);

    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump();
    expect(calls, 1);

    scheduler.dispose();
  });

  testWidgets('queues at most one refresh while a refresh is running',
      (tester) async {
    var calls = 0;
    final firstGate = Completer<void>();
    final secondGate = Completer<void>();
    final scheduler = RealtimeRefreshScheduler(
      debounce: const Duration(milliseconds: 10),
      handler: () async {
        calls += 1;
        await (calls == 1 ? firstGate.future : secondGate.future);
      },
    );

    final refresh = scheduler.refreshNow();
    expect(calls, 1);
    scheduler.schedule();
    scheduler.schedule();
    await tester.pump(const Duration(milliseconds: 10));

    firstGate.complete();
    await tester.pump();
    expect(calls, 2);

    secondGate.complete();
    await refresh;
    scheduler.dispose();
  });

  testWidgets('dispose cancels a pending debounce', (tester) async {
    var calls = 0;
    final scheduler = RealtimeRefreshScheduler(
      debounce: const Duration(milliseconds: 20),
      handler: () async => calls += 1,
    );

    scheduler.schedule();
    scheduler.dispose();
    await tester.pump(const Duration(milliseconds: 25));

    expect(calls, 0);
    expect(scheduler.isScheduled, isFalse);
  });

  testWidgets('dispose while running drops the queued second pass',
      (tester) async {
    var calls = 0;
    final gate = Completer<void>();
    final scheduler = RealtimeRefreshScheduler(
      handler: () async {
        calls += 1;
        await gate.future;
      },
    );

    final running = scheduler.refreshNow();
    scheduler.schedule();
    scheduler.dispose();
    gate.complete();
    await running;
    await tester.pump();

    expect(calls, 1);
    expect(scheduler.isRefreshing, isFalse);
  });

  test('session switch waits for the previous running refresh', () async {
    final oldRefreshGate = Completer<void>();
    final oldScheduler = RealtimeRefreshScheduler(
      handler: () => oldRefreshGate.future,
    );
    oldScheduler.refreshNow();
    oldScheduler.dispose();

    var newSessionRefreshStarted = false;
    final resumeNewSession = () async {
      await oldScheduler.settled;
      newSessionRefreshStarted = true;
    }();

    await Future<void>.delayed(Duration.zero);
    expect(newSessionRefreshStarted, isFalse);

    oldRefreshGate.complete();
    await resumeNewSession;
    expect(newSessionRefreshStarted, isTrue);
  });

  test('generation gate rejects old channel and old logical session', () {
    final gate = RealtimeGenerationGate();
    final sessionA = gate.sessionGeneration;
    final channelA = gate.nextChannel('core');

    expect(
      gate.accepts(
        domain: 'core',
        channelGeneration: channelA,
        sessionGeneration: sessionA,
      ),
      isTrue,
    );

    final channelB = gate.nextChannel('core');
    expect(
      gate.accepts(
        domain: 'core',
        channelGeneration: channelA,
        sessionGeneration: sessionA,
      ),
      isFalse,
    );
    expect(
      gate.accepts(
        domain: 'core',
        channelGeneration: channelB,
        sessionGeneration: sessionA,
      ),
      isTrue,
    );

    gate.nextSession();
    expect(
      gate.accepts(
        domain: 'core',
        channelGeneration: channelB,
        sessionGeneration: sessionA,
      ),
      isFalse,
    );
  });

  testWidgets('reconnect scheduler deduplicates, cancels, and rejects stale',
      (tester) async {
    final reconnects = <String>[];
    var current = true;
    final scheduler = RealtimeReconnectScheduler();

    expect(
      scheduler.schedule(
        domain: 'core',
        delay: const Duration(milliseconds: 10),
        isCurrent: () => current,
        reconnect: () => reconnects.add('first'),
      ),
      isTrue,
    );
    expect(
      scheduler.schedule(
        domain: 'core',
        delay: const Duration(milliseconds: 10),
        isCurrent: () => true,
        reconnect: () => reconnects.add('duplicate'),
      ),
      isFalse,
    );
    expect(scheduler.pendingCount, 1);

    current = false;
    await tester.pump(const Duration(milliseconds: 10));
    expect(reconnects, isEmpty);
    expect(scheduler.pendingCount, 0);

    scheduler.schedule(
      domain: 'planning',
      delay: const Duration(milliseconds: 10),
      isCurrent: () => true,
      reconnect: () => reconnects.add('cancelled'),
    );
    scheduler.cancelAll();
    await tester.pump(const Duration(milliseconds: 10));
    expect(reconnects, isEmpty);
  });

  test('duplicate owner registration replaces its previous callback', () async {
    final service = RealtimeSyncService.instance;
    final owner = Object();
    var first = 0;
    var second = 0;

    service.registerRefreshHandler(
      owner: owner,
      resource: RealtimeResource.suppliers,
      handler: () async => first += 1,
    );
    service.registerRefreshHandler(
      owner: owner,
      resource: RealtimeResource.suppliers,
      handler: () async => second += 1,
    );

    await service.debugRefreshResource(RealtimeResource.suppliers);
    expect(first, 0);
    expect(second, 1);
    expect(service.diagnostics.handlerCounts['suppliers'], 1);

    service.unregisterOwner(owner);
    await service.debugRefreshResource(RealtimeResource.suppliers);
    expect(second, 1, reason: 'an event after unregister must not call owner');
  });

  test('unregister removes only the selected owner', () async {
    final service = RealtimeSyncService.instance;
    final ownerA = Object();
    final ownerB = Object();
    var callsA = 0;
    var callsB = 0;

    service.registerRefreshHandler(
      owner: ownerA,
      resource: RealtimeResource.forms,
      handler: () async => callsA += 1,
    );
    service.registerRefreshHandler(
      owner: ownerB,
      resource: RealtimeResource.forms,
      handler: () async => callsB += 1,
    );

    await service.debugRefreshResource(RealtimeResource.forms);
    expect((callsA, callsB), (1, 1));

    service.unregisterOwner(ownerA);
    await service.debugRefreshResource(RealtimeResource.forms);
    expect((callsA, callsB), (1, 2));

    service.unregisterOwner(ownerB);
  });

  test('shared manifest has five domains and excludes audited no-op tables',
      () {
    expect(RealtimeSyncService.debugDeclaredDomainCount, 5);
    expect(RealtimeSyncService.debugDeclaredTables.length, 66);
    expect(
      RealtimeSyncService.debugDeclaredTables,
      contains('production.plan_stages'),
    );
    const removed = <String>{
      'public.order_files',
      'public.order_events',
      'public.order_paints',
      'public.order_consumption_snapshots',
      'public.order_paint_pending_writeoffs',
      'public.analytics',
      'public.workplace_setup_history',
    };
    expect(
        RealtimeSyncService.debugDeclaredTables.intersection(removed), isEmpty);
  });

  test('first realtime read waits until queue bootstrap completes', () async {
    final bootstrap = Completer<void>();
    var reads = 0;
    final refresh = afterProductionQueueBootstrap(
      bootstrap.future,
      () async => reads += 1,
    );

    await Future<void>.delayed(Duration.zero);
    expect(reads, 0);
    bootstrap.complete();
    await refresh;
    expect(reads, 1);
  });

  test('only bootstrap may seed an empty legacy queue', () {
    expect(
      ProductionQueueProvider.shouldSeedLegacyRemote(
        seedRemoteWhenEmpty: true,
        remoteIsEmpty: true,
        localIsEmpty: false,
      ),
      isTrue,
    );
    expect(
      ProductionQueueProvider.shouldSeedLegacyRemote(
        seedRemoteWhenEmpty: false,
        remoteIsEmpty: true,
        localIsEmpty: false,
      ),
      isFalse,
      reason: 'realtime and polling pass seedRemoteWhenEmpty=false',
    );
  });

  test('migration publication matches the audited client manifest', () {
    final sql = File(
      'supabase/migrations/20260812_enable_targeted_realtime.sql',
    ).readAsStringSync();
    final allowList = RegExp(
      r'-- Orders, workspace.*?\]\s*loop',
      dotAll: true,
    ).firstMatch(sql)!.group(0)!;
    final published =
        RegExp(r"'((?:public|production)\.[^']+)'", caseSensitive: false)
            .allMatches(allowList)
            .map((match) => match.group(1)!)
            .toSet();

    final expected = <String>{
      ...RealtimeSyncService.debugDeclaredTables,
      'public.chat_messages',
    };
    expect(published, expected);
    expect(sql.toLowerCase(), contains('security invoker'));
    expect(
      sql.toLowerCase(),
      contains(
        'alter publication supabase_realtime drop table',
      ),
    );
    expect(
      sql.toLowerCase(),
      isNot(contains(
          'grant execute on function public.realtime_sync_published_tables() to anon')),
    );
  });
}
