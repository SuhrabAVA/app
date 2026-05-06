import 'package:flutter_test/flutter_test.dart';
import 'package:sheet_clone/modules/orders/order_stage_filter.dart'
    hide kBottomWithCardboardAssemblyStageId,
        kCardboardCuttingStageId,
        kCardboardInsertStageId;
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

  test('sheet products contain only the sheet UUID', () {
    expect(kSheetProducts, {kSheetProductTypeId});
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

  test('builds v-type package route with trimming before final packaging', () {
    final result = buildOrderStages(
      const OrderStageQueueDraft(
        productTypeId: kVTypeProductId,
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
        kVMainSwitchStageKey,
        kCuttingStageId,
        kPackagingStageId,
      ],
    );
    expect(result[2].stageName, 'Фри');
    expect(result[2].isSwitchable, isTrue);
    expect(result[3].stageName, 'Резка');
    expect(result.last.stageName, 'Упаковка');
  });

  test('does not add bobbin cutting without positive widths', () {
    final result = buildOrderStages(
      const OrderStageQueueDraft(
        productTypeId: 'Листы',
        orderWidthB: 0,
        materialWidth: 600,
        hasPaint: false,
        hasTrimming: false,
        hasCardboard: false,
      ),
    );

    expect(
      result.map((stage) => stage.stageKey),
      isNot(contains(kBobbinStageId)),
    );
  });

  test(
    'builds two-sheet package route with trimming, cardboard and flat handle',
    () {
    final result = buildOrderStages(
      const OrderStageQueueDraft(
        productTypeId: kTwoSheetPackageProductTypeId,
        orderWidthB: 300,
        materialWidth: 600,
        hasPaint: true,
        hasTrimming: true,
        hasCardboard: true,
        handleType: OrderHandleType.flat,
      ),
    );

    final dieCutStage = result.singleWhere(
      (stage) => stage.stageKey == kDieCutA1A2StageId,
    );
    final bottomGlueStage = result.singleWhere(
      (stage) => stage.stageKey == kBottomGlueStageId,
    );
    final flatHandleStage = result.singleWhere(
      (stage) => stage.stageKey == kFlatHandleGroupStageId,
    );

    expect(
      result.map((stage) => stage.stageKey),
      [
        kBobbinStageId,
        kFlexPrintingStageId,
        kSheetCutStageId,
        kCuttingStageId,
        kDieCutA1A2StageId,
        kScotchStageId,
        kFromTwoSheetsStageId,
        kTubeAssemblyStageId,
        kCardboardCuttingStageId,
        kBottomWithCardboardAssemblyStageId,
        kBottomGlueStageId,
        kFlatHandleGroupStageId,
        kPackagingStageId,
      ],
    );
    expect(
      result.map((stage) => stage.stageKey),
      isNot(contains(kCardboardInsertStageId)),
    );
    expect(dieCutStage.workplaceIds, [
      kDieCutA1WorkplaceId,
      kDieCutA2WorkplaceId,
    ]);
    expect(bottomGlueStage.workplaceIds, [
      kBottomGlueWorkplaceId,
      kBottomGlueAltWorkplaceId,
      kBottomGlueSecondAltWorkplaceId,
    ]);
    expect(flatHandleStage.workplaceIds, [
      kFlatHandleStageId,
      kManualHandleStageId,
    ]);
    expect(result.last.stageKey, kPackagingStageId);
  });

  test(
    'builds two-sheet package route without trimming or cardboard and with twisted handle',
    () {
    final result = buildOrderStages(
      const OrderStageQueueDraft(
        productTypeId: kTwoSheetPackageProductTypeId,
        orderWidthB: 600,
        materialWidth: 600,
        hasPaint: false,
        hasTrimming: false,
        hasCardboard: false,
        handleType: OrderHandleType.twisted,
      ),
    );

    final twistedHandleStage = result.singleWhere(
      (stage) => stage.stageKey == kTwistedHandleGroupStageId,
    );

    expect(
      result.map((stage) => stage.stageKey),
      [
        kSheetCutStageId,
        kDieCutA1A2StageId,
        kScotchStageId,
        kFromTwoSheetsStageId,
        kTubeAssemblyStageId,
        kBottomWithCardboardAssemblyStageId,
        kBottomGlueStageId,
        kTwistedHandleGroupStageId,
        kPackagingStageId,
      ],
    );
    expect(
      result.map((stage) => stage.stageKey),
      isNot(contains(kCuttingStageId)),
    );
    expect(
      result.map((stage) => stage.stageKey),
      isNot(contains(kCardboardCuttingStageId)),
    );
    expect(twistedHandleStage.workplaceIds, [
      kTwistedHandleStageId,
      kManualHandleStageId,
    ]);
  });

  test('builds two-sheet package route with die cut handle', () {
    final result = buildOrderStages(
      const OrderStageQueueDraft(
        productTypeId: kTwoSheetPackageProductTypeId,
        orderWidthB: 600,
        materialWidth: 600,
        hasPaint: false,
        hasTrimming: true,
        hasCardboard: false,
        handleType: OrderHandleType.dieCut,
      ),
    );

    final handleStage = result.singleWhere(
      (stage) => stage.stageKey == kDieCutHandleStageId,
    );

    expect(
      result.map((stage) => stage.stageKey),
      [
        kSheetCutStageId,
        kCuttingStageId,
        kDieCutA1A2StageId,
        kScotchStageId,
        kFromTwoSheetsStageId,
        kTubeAssemblyStageId,
        kBottomWithCardboardAssemblyStageId,
        kBottomGlueStageId,
        kDieCutHandleStageId,
        kPackagingStageId,
      ],
    );
    expect(handleStage.stageName, 'Вырубка');
    expect(handleStage.workplaceIds, [kDieCutHandleStageId]);
  });

  test('builds twisted handle as one multi-workplace stage', () {
    final result = buildOrderStages(
      const OrderStageQueueDraft(
        productTypeId: kPTypePackageProduct,
        orderWidthB: 600,
        materialWidth: 600,
        hasPaint: false,
        hasTrimming: false,
        hasCardboard: false,
        handleType: OrderHandleType.twisted,
      ),
    );

    final handleStage = result.singleWhere(
      (stage) => stage.stageKey == kTwistedHandleGroupStageId,
    );
    expect(handleStage.stageName, 'Кручёная ручка');
    expect(handleStage.workplaceIds, [
      kTwistedHandleStageId,
      kManualHandleStageId,
    ]);
  });

  test('builds die cut handle as one stage', () {
    final result = buildOrderStages(
      const OrderStageQueueDraft(
        productTypeId: kPTypePackageProduct,
        orderWidthB: 600,
        materialWidth: 600,
        hasPaint: false,
        hasTrimming: false,
        hasCardboard: false,
        handleType: OrderHandleType.dieCut,
      ),
    );

    final handleStage = result.singleWhere(
      (stage) => stage.stageKey == kDieCutHandleStageId,
    );
    expect(handleStage.stageName, 'Вырубка');
    expect(handleStage.workplaceIds, [kDieCutHandleStageId]);
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

    expect(result.first.stageKey, kPMainSwitchStageKey);
    expect(result.first.isSwitchable, isTrue);
    expect(result.first.selectedWorkplaceId, kTubeStageId);
    expect(result.last.stageKey, kPackagingStageId);
  });

  test('keeps switchable selections by stage key when rebuilding queue', () {
    final result = buildOrderStageQueue(
      productTypeId: kPTypePackageProduct,
      hasCutting: false,
      hasCardboard: true,
      hasFlexPrinting: false,
      selectedSwitchableStageIdsByStageKey: const {
        kPMainSwitchStageKey: kTubeStageId,
      },
    );

    final switchStage = result.singleWhere(
      (stage) => stage['stageKey'] == kPMainSwitchStageKey,
    );
    expect(switchStage['stageId'], kTubeStageId);
    expect(switchStage['workplaceId'], kTubeStageId);
    expect(switchStage['selectedWorkplaceId'], kTubeStageId);
    expect(switchStage['stageName'], 'Труба');
    expect(switchStage['isSwitchable'], isTrue);
    expect(switchStage['switchableGroupKey'], kSwitchablePGroupKey);
  });

  test('toggles full switchable stage object metadata', () {
    final toggled = toggleProductStageObject({
      'stageKey': kVMainSwitchStageKey,
      'stageId': kFriStageId,
      'workplaceId': kFriStageId,
      'selectedWorkplaceId': kFriStageId,
      'stageName': 'Фри',
      'isSwitchable': true,
      'switchableGroupKey': kSwitchableVGroupKey,
      'workplaceIds': [kFriStageId, kWindowStageId],
    });

    expect(toggled, isNotNull);
    expect(toggled!['stageKey'], kVMainSwitchStageKey);
    expect(toggled['stageId'], kWindowStageId);
    expect(toggled['workplaceId'], kWindowStageId);
    expect(toggled['selectedWorkplaceId'], kWindowStageId);
    expect(toggled['stageName'], 'Окно');
    expect(toggled['workplaceName'], 'Окно');
  });

}
