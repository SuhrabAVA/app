import 'package:flutter_test/flutter_test.dart';
import 'package:sheet_clone/modules/orders/order_stage_filter.dart';
import 'package:sheet_clone/modules/orders/stage_queue_builder.dart';

void main() {
  test('inserts product stage after bobbin/flexo base stages', () {
    final queue = [
      {'stageId': kBobbinStageId, 'stageName': 'Бобинорезка'},
      {'stageId': kFlexPrintingStageId, 'stageName': 'Флексопечать'},
    ];

    final result = insertProductStageAfterBaseStages(
      queue,
      {'stageId': kFriStageId, 'stageName': 'Фри'},
    );

    expect(result[2]['stageId'], kFriStageId);
  });

  test('inserts product stage first when base stages are missing', () {
    final result = insertProductStageAfterBaseStages(
      const [],
      {'stageId': kSheetCutStageId, 'stageName': 'Листорезка'},
    );

    expect(result.first['stageId'], kSheetCutStageId);
  });

  test('builds sheet queue from centralized draft rules', () {
    final result = buildOrderStages(
      const OrderStageQueueDraft(
        productTypeId: 'Листы',
        orderWidthB: 300,
        materialWidth: 600,
        hasPaint: true,
        hasTrimming: true,
        hasCardboard: false,
      ),
    );

    expect(
      result.map((stage) => stage.stageKey),
      [
        kBobbinStageId,
        kFlexPrintingStageId,
        kSheetCutStageId,
        kCuttingStageId,
        kPackagingStageId,
      ],
    );
    expect(result.last.stageKey, kPackagingStageId);
    expect(result.last.sortOrder, result.length);
  });

  test('keeps separate two-sheet technological stages with unique stage keys', () {
    final result = buildOrderStages(
      const OrderStageQueueDraft(
        productTypeId: 'Пакет из 2х листов',
        orderWidthB: 600,
        materialWidth: 600,
        hasPaint: false,
        hasTrimming: false,
        hasCardboard: true,
        handleType: OrderHandleType.flat,
      ),
    );

    expect(result.map((stage) => stage.stageKey), containsAll([
      'die_cut_a1',
      'die_cut_a2',
      kCardboardStageId,
      kFlatHandleStageId,
      kPackagingStageId,
    ]));
    expect(result.last.stageKey, kPackagingStageId);
  });

  test('builds switchable p-package stage with selected tube workplace', () {
    final result = buildOrderStages(
      const OrderStageQueueDraft(
        productTypeId: kPTypePackageProduct,
        orderWidthB: 600,
        materialWidth: 600,
        hasPaint: false,
        hasTrimming: false,
        hasCardboard: false,
        selectedSwitchableStageId: kTubeStageId,
      ),
    );

    expect(result.first.stageKey, kSwitchablePGroupKey);
    expect(result.first.isSwitchable, isTrue);
    expect(result.first.selectedWorkplaceId, kTubeStageId);
    expect(result.last.stageKey, kPackagingStageId);
  });
}
