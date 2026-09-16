import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sheet_clone/services/realtime_sync_service.dart';
import 'package:sheet_clone/services/stock_availability_recheck_coordinator.dart';

void main() {
  const migrationPath =
      'supabase/migrations/20260813_atomic_pens_completion_writeoff.sql';

  test('stock realtime refreshes projections and never routes to orders', () {
    expect(
      RealtimeSyncService.debugResourcesForTable('materials'),
      {RealtimeResource.warehouseMaterials},
    );
    expect(
      RealtimeSyncService.debugResourcesForTable('papers'),
      {RealtimeResource.warehousePapers},
    );
    for (final table in const [
      'materials_arrivals',
      'materials_writeoffs',
      'materials_inventories',
      'papers_arrivals',
      'papers_writeoffs',
      'papers_inventories',
    ]) {
      expect(RealtimeSyncService.debugResourcesForTable(table), isEmpty);
    }
  });

  test('queue realtime handlers contain reads only and never save', () {
    final source = File(
      'lib/modules/production/production_queue_provider.dart',
    ).readAsStringSync();
    final start = source.indexOf('Future<void> refreshLegacyRemoteState');
    final end = source.indexOf('Future<void> refreshRemoteState', start);
    final handlers = source.substring(start, end);

    expect(handlers, contains('await _loadLegacyRemote();'));
    expect(handlers, contains('await _loadAllWorkplacePositions();'));
    expect(handlers, isNot(contains('_pushLocalStateToLegacyRemote')));
    expect(handlers, isNot(contains('seedRemoteWhenEmpty: true')));
    expect(handlers, isNot(matches(RegExp(r'\.(insert|update|upsert)\('))));
  });

  test('one canonical stock command invokes exactly one calculation', () async {
    final coordinator = StockAvailabilityRecheckCoordinator();
    final owner = Object();
    var calculations = 0;
    coordinator.register(
      owner: owner,
      handler: () async => calculations += 1,
    );

    await coordinator.afterCommittedStockMutation();

    expect(calculations, 1);
    coordinator.unregister(owner);
  });

  test('concurrent stock commands are serialized without dropping a pass',
      () async {
    final coordinator = StockAvailabilityRecheckCoordinator();
    final firstGate = Completer<void>();
    var calls = 0;
    var active = 0;
    var maxActive = 0;
    coordinator.register(
      owner: Object(),
      handler: () async {
        calls += 1;
        active += 1;
        if (active > maxActive) maxActive = active;
        if (calls == 1) await firstGate.future;
        active -= 1;
      },
    );

    final first = coordinator.afterCommittedStockMutation();
    final second = coordinator.afterCommittedStockMutation();
    await Future<void>.delayed(Duration.zero);
    expect(calls, 1);
    firstGate.complete();
    await Future.wait([first, second]);

    expect(calls, 2);
    expect(maxActive, 1);
  });

  test('repeated pens completion is an atomic no-op after first insert', () {
    final sql = File(migrationPath).readAsStringSync().toLowerCase();
    expect(sql, contains('on conflict (order_id)'));
    expect(sql, contains('where order_id is not null do nothing'));
    expect(sql, isNot(contains('select id\n            .from')));
  });

  test('concurrent pens completion has a database-enforced natural key', () {
    final sql = File(migrationPath).readAsStringSync().toLowerCase();
    expect(sql, contains('create unique index if not exists'));
    expect(sql, contains('warehouse_pens_writeoffs_one_per_order_uidx'));
    expect(sql, contains('for update'));
    expect(sql, contains('returning id into v_writeoff_id'));
  });

  test('test mode uses the canonical completion RPC', () {
    final source = File(
      'lib/modules/production/production_details_screen.dart',
    ).readAsStringSync();
    final start = source.indexOf('Future<void> _skipStageForTesting');
    final end = source.indexOf('TaskStatus? _groupStatus', start);
    final method = source.substring(start, end);

    expect(method, contains('repository.completeTaskStage('));
    expect(method, contains("'status': TaskStatus.waiting.name"));
    expect(method, isNot(contains('provider.updateStatus(')));
    expect(method, isNot(contains("'status': TaskStatus.completed.name")));
  });

  test(
      'timeout retry remains safe because trigger and ledger share transaction',
      () {
    final sql = File(migrationPath).readAsStringSync().toLowerCase();
    expect(sql.trimLeft(), startsWith('begin;'));
    expect(sql.trimRight(), endsWith('commit;'));
    expect(sql, contains('after insert or update on public.orders'));
    expect(sql, contains('record_order_pens_completion_writeoff'));
    expect(sql, contains('on conflict (order_id)'));
  });

  test('identical completion cannot create a second writeoff', () {
    final sql = File(migrationPath).readAsStringSync().toLowerCase();
    expect(
      sql,
      contains("if lower(coalesce(old.status, '')) = 'completed'"),
    );
    expect(sql, contains('return v_writeoff_id is not null'));
  });

  test('duplicate diagnostic and migration never remediate history', () {
    final diagnostic = File(
      'supabase/diagnostics/pens_completion_writeoff_duplicates.sql',
    ).readAsStringSync().toLowerCase();
    final migration = File(migrationPath).readAsStringSync().toLowerCase();

    expect(diagnostic, contains('having count(*) > 1'));
    expect(diagnostic, isNot(matches(RegExp(r'\b(delete|update|insert)\b'))));
    expect(migration, contains('values block the migration'));
    expect(migration, isNot(matches(RegExp(r'\bdelete\s+from\b'))));
  });
}
