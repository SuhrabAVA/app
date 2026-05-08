import 'package:flutter_test/flutter_test.dart';
import 'package:sheet_clone/modules/orders/order_queue_service.dart';
import 'package:sheet_clone/modules/production/production_details_screen.dart';
import 'package:sheet_clone/modules/tasks/stage_sequence_utils.dart';

OrderQueueLoadSources _sources({
  Map<String, dynamic>? orderColumns,
  Map<String, dynamic>? orderData,
  List<Map<String, dynamic>> normalizedRows = const <Map<String, dynamic>>[],
  List<Map<String, dynamic>> legacyRows = const <Map<String, dynamic>>[],
  List<Map<String, dynamic>> templateRows = const <Map<String, dynamic>>[],
}) {
  return OrderQueueLoadSources(
    loadOrderQueueColumns: (_) async => orderColumns,
    loadOrderData: (_) async => orderData,
    loadNormalizedRows: (_) async => normalizedRows,
    loadLegacyProductionPlanRows: (_) async => legacyRows,
    loadTemplateFallbackRows: (_) async => templateRows,
  );
}

void main() {
  test(
    'loadSavedQueue prefers normalized plan rows over stale order JSON',
    () async {
      final service = OrderQueueService.withLoadSources(_sources(
        orderColumns: const {
          'stage_queue': [
            {'stage_id': 'old-cut', 'step_no': 1},
            {'stage_id': 'old-pack', 'step_no': 2},
          ],
        },
        orderData: const {
          'order_stage_queue': [
            {'stage_id': 'old-data-cut', 'step_no': 1},
          ],
        },
        normalizedRows: const [
          {'stage_id': 'new-print', 'stage_name': 'Печать', 'seq': 1},
          {'stage_id': 'new-pack', 'stage_name': 'Упаковка', 'seq': 2},
        ],
      ));

      final saved = await service.loadSavedQueue(' order-1 ');

      expect(saved.orderId, 'order-1');
      expect(saved.source, SavedOrderQueueSource.normalizedPlanRows);
      expect(
        saved.rows.map((row) => row['stage_id']),
        ['new-print', 'new-pack'],
      );
    },
  );

  test(
    'loadSavedQueue order matches ProductionDetailsScreen and '
    'TaskProvider sequence',
    () async {
      final service = OrderQueueService.withLoadSources(_sources(
        orderColumns: const {
          'stage_queue': [
            {'stage_id': 'old-stage', 'step_no': 1},
          ],
        },
        normalizedRows: const [
          {'stage_id': 'cut', 'stage_name': 'Резка', 'seq': 1},
          {'stage_id': 'print', 'stage_name': 'Печать', 'seq': 2},
          {'stage_id': 'pack', 'stage_name': 'Упаковка', 'seq': 3},
        ],
      ));

      final saved = await service.loadSavedQueue('order-2');
      final productionStageIds =
          productionDetailsPlannedStagesFromQueueRowsForTesting(
        rows: saved.rows,
      )
          .map((stage) => stage.stageId)
          .toList();
      final taskProviderStageIds = normalizeStageSequence(
        OrderQueueMapper.toSyncEntries(saved.rows).map((entry) => entry.stageId),
      );

      expect(saved.source, SavedOrderQueueSource.normalizedPlanRows);
      expect(productionStageIds, ['cut', 'print', 'pack']);
      expect(taskProviderStageIds, productionStageIds);
    },
  );

  test(
    'loadSavedQueue uses order JSON only when normalized rows are absent',
    () async {
      final service = OrderQueueService.withLoadSources(_sources(
        orderColumns: const {
          'order_stage_queue': [
            {'stage_id': 'saved-cut', 'step_no': 1},
            {'stage_id': 'saved-pack', 'step_no': 2},
          ],
        },
      ));

      final saved = await service.loadSavedQueue('order-3');

      expect(saved.source, SavedOrderQueueSource.savedOrderQueue);
      expect(
        saved.rows.map((row) => row['stage_id']),
        ['saved-cut', 'saved-pack'],
      );
    },
  );
}
