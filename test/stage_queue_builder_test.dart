import 'package:flutter_test/flutter_test.dart';
import 'package:sheet_clone/modules/orders/material_model.dart';
import 'package:sheet_clone/modules/orders/order_stage_filter.dart'
    hide kBottomWithCardboardAssemblyStageId,
        kCardboardCuttingStageId,
        kCardboardInsertStageId;
import 'package:sheet_clone/modules/orders/order_model.dart';
import 'package:sheet_clone/modules/orders/product_model.dart';
import 'package:sheet_clone/modules/orders/stage_queue_builder.dart';
import 'package:sheet_clone/modules/production/production_screen.dart';
import 'package:sheet_clone/modules/production_planning/planned_stage_model.dart';
import 'package:sheet_clone/modules/production_planning/template_model.dart';
import 'package:sheet_clone/modules/tasks/task_model.dart';

void main() {
  void expectBuiltStages(
    List<BuiltOrderStage> stages,
    List<String> expectedStageKeys, {
    Map<String, List<String>> workplaceIdsByStageKey = const {},
    Map<String, String?> selectedWorkplaceIdsByStageKey = const {},
  }) {
    expect(stages.map((stage) => stage.stageKey).toList(), expectedStageKeys);
    for (var index = 0; index < stages.length; index += 1) {
      final stage = stages[index];
      expect(
        stage.sortOrder,
        index + 1,
        reason: '${stage.stageKey} sortOrder must follow queue order',
      );
      expect(stage.workplaceIds, isNotEmpty);
      expect(
        stage.selectedWorkplaceId,
        selectedWorkplaceIdsByStageKey.containsKey(stage.stageKey)
            ? selectedWorkplaceIdsByStageKey[stage.stageKey]
            : stage.workplaceIds.first,
        reason: '${stage.stageKey} selectedWorkplaceId',
      );
    }
    workplaceIdsByStageKey.forEach((stageKey, workplaceIds) {
      expect(
        stages.singleWhere((stage) => stage.stageKey == stageKey).workplaceIds,
        workplaceIds,
        reason: '$stageKey workplaceIds',
      );
    });
  }

  void expectQueueMaps(
    List<Map<String, dynamic>> queue,
    List<String> expectedStageKeys, {
    Map<String, List<String>> workplaceIdsByStageKey = const {},
    Map<String, String?> selectedWorkplaceIdsByStageKey = const {},
  }) {
    expect(queue.map((stage) => stage['stageKey']).toList(), expectedStageKeys);
    for (var index = 0; index < queue.length; index += 1) {
      final stage = queue[index];
      final stageKey = stage['stageKey'] as String;
      final workplaceIds = (stage['workplaceIds'] as List).cast<String>();
      final selectedWorkplaceId = selectedWorkplaceIdsByStageKey
              .containsKey(stageKey)
          ? selectedWorkplaceIdsByStageKey[stageKey]
          : workplaceIds.first;

      expect(stage['sortOrder'], index + 1, reason: '$stageKey sortOrder');
      expect(stage['order'], index + 1, reason: '$stageKey order');
      expect(workplaceIds, isNotEmpty, reason: '$stageKey workplaceIds');
      expect(stage['selectedWorkplaceId'], selectedWorkplaceId);
      expect(stage['stageId'], selectedWorkplaceId);
      expect(stage['workplaceId'], selectedWorkplaceId);
    }
    workplaceIdsByStageKey.forEach((stageKey, workplaceIds) {
      expect(
        (queue.singleWhere((stage) => stage['stageKey'] == stageKey)
                ['workplaceIds'] as List)
            .cast<String>(),
        workplaceIds,
        reason: '$stageKey workplaceIds',
      );
    });
  }

  test('production stage groups follow saved queue and selected P workplace', () {
    final order = OrderModel(
      id: 'order-with-p-queue',
      manager: '',
      customer: 'Test customer',
      orderDate: DateTime(2026, 5, 8),
      dueDate: null,
      product: ProductModel(
        id: 'product',
        type: kPTypePackageProduct,
        quantity: 1000,
        width: 0,
        height: 0,
        depth: 0,
      ),
      stageTemplateId: 'legacy-template',
    );

    const plannedSequence = [
      kBobbinStageId,
      kAutoBigStageId,
      kAutoSmallStageId,
      kTubeStageId,
      kCuttingStageId,
      kCardboardCuttingStageId,
      kCardboardInsertStageId,
      kTwistedHandleStageId,
      kPackagingStageId,
    ];
    const stageNames = {
      kBobbinStageId: 'Бобинорезка',
      kAutoBigStageId: 'Автомат большой',
      kAutoSmallStageId: 'Автомат маленький',
      kTubeStageId: 'Труба',
      kCuttingStageId: 'Резка',
      kCardboardCuttingStageId: 'Резка картона',
      kCardboardInsertStageId: 'Вставка картона',
      kTwistedHandleStageId: 'Кручёная ручка',
      kPackagingStageId: 'Упаковка',
    };
    const stageGroupMap = {
      kAutoBigStageId: kSwitchablePGroupKey,
      kAutoSmallStageId: kSwitchablePGroupKey,
      kTubeStageId: kSwitchablePGroupKey,
    };

    TaskModel task(String stageId, {String? groupKey}) => TaskModel(
          id: 'task-$stageId',
          orderId: order.id,
          stageId: stageId,
          stageGroupKey: groupKey ?? stageId,
        );

    final labels = productionStageLabelsForTesting(
      order: order,
      plannedSequence: plannedSequence,
      stageGroupMap: stageGroupMap,
      stageNames: stageNames,
      templates: [
        TemplateModel(
          id: 'legacy-template',
          name: 'Legacy template must not override saved queue',
          stages: [
            PlannedStage(stageId: kPackagingStageId, stageName: 'Упаковка'),
            PlannedStage(
              stageId: kAutoBigStageId,
              stageName: 'Автомат большой',
              workplaceIds: const [
                kAutoBigStageId,
                kAutoSmallStageId,
                kTubeStageId,
              ],
              alternativeStageNames: const [
                'Автомат маленький',
                'Труба',
              ],
            ),
          ],
        ),
      ],
      orderTasks: [
        task(kBobbinStageId),
        task(kAutoBigStageId, groupKey: kSwitchablePGroupKey),
        task(kCuttingStageId),
        task(kCardboardCuttingStageId),
        task(kCardboardInsertStageId),
        task(kTwistedHandleStageId),
        task(kPackagingStageId),
      ],
    );

    expect(labels, [
      'Бобинорезка',
      'Автомат большой',
      'Резка',
      'Резка картона',
      'Вставка картона',
      'Кручёная ручка',
      'Упаковка',
    ]);
    expect(
      labels,
      isNot(contains('Автомат большой / Автомат маленький / Труба')),
    );
  });

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

  test('recognizes named V-type products as switchable V routes', () {
    for (final productTypeName in const [
      'В-образный окно',
      'В-образный пакет',
      'В-образный фри',
      'В-образный уголок',
    ]) {
      final result = buildOrderStages(
        OrderStageQueueDraft(
          productTypeId: productTypeName,
          orderWidthB: 600,
          materialWidth: 600,
          hasPaint: false,
          hasTrimming: false,
          hasCardboard: false,
        ),
      );

      expect(result.first.stageKey, kVMainSwitchStageKey);
      expect(result.first.selectedWorkplaceId, kFriStageId);
      expect(result.last.stageKey, kPackagingStageId);
    }
  });


  test('centralized bobbin rule checks all selected papers', () {
    final result = buildOrderStages(
      OrderStageQueueDraft(
        productTypeId: 'Листы',
        orderWidthB: 600,
        materialWidth: 600,
        requiresBobbinCutting: requiresBobbinCuttingForOrder(
          defaultOrderWidthB: 600,
          papers: const [
            MaterialModel(name: 'Main', quantity: 1, unit: 'м', format: '600'),
            MaterialModel(
              name: 'Extra',
              quantity: 1,
              unit: 'м',
              format: '700',
              extra: {'widthB': 300},
            ),
          ],
        ),
        hasPaint: false,
        hasTrimming: false,
        hasCardboard: false,
      ),
    );

    expect(result.map((stage) => stage.stageKey), contains(kBobbinStageId));
  });

  test('normalizes base stage aliases without changing composition', () {
    final result = normalizeBuiltOrderStageQueue([
      {'stageId': kPackagingStageId, 'stageName': 'Упаковка'},
      {'stageId': kSheetCutStageId, 'stageName': 'Листорезка'},
      {'stageId': 'w_flexoprint', 'stageName': 'Flexo'},
      {'stageId': 'w_bobiner', 'stageName': 'Бобинорезка'},
    ]);

    expect(
      result.map((stage) => stage['stageId']),
      [
        kBobbinStageId,
        kFlexPrintingStageId,
        kSheetCutStageId,
        kPackagingStageId,
      ],
    );
    expect(result[0]['stageName'], 'Бабинорезка');
    expect(result[1]['stageName'], 'Флексопечать');
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

  test('builds p-package route for selected big automatic workplace', () {
    final result = buildOrderStages(
      const OrderStageQueueDraft(
        productTypeId: kPTypePackageProduct,
        orderWidthB: 600,
        materialWidth: 600,
        hasPaint: false,
        hasTrimming: true,
        hasCardboard: true,
        handleType: OrderHandleType.flat,
        selectedSwitchableStageId: kAutoBigStageId,
      ),
    );

    final switchStage = result.first;
    final handleStage = result.singleWhere(
      (stage) => stage.stageKey == kFlatHandleGroupStageId,
    );

    expect(
      result.map((stage) => stage.stageKey),
      [
        kPMainSwitchStageKey,
        kCuttingStageId,
        kCardboardCuttingStageId,
        kCardboardInsertStageId,
        kFlatHandleGroupStageId,
        kPackagingStageId,
      ],
    );
    expect(switchStage.stageName, 'Автомат большой');
    expect(switchStage.selectedWorkplaceId, kAutoBigStageId);
    expect(switchStage.workplaceIds, [
      kAutoBigStageId,
      kAutoSmallStageId,
      kTubeStageId,
    ]);
    expect(
      result.map((stage) => stage.stageKey),
      isNot(contains(kBottomWithCardboardAssemblyStageId)),
    );
    expect(
      result.map((stage) => stage.stageKey),
      isNot(contains(kBottomGlueStageId)),
    );
    expect(handleStage.workplaceIds, [
      kFlatHandleStageId,
      kManualHandleStageId,
    ]);
  });

  test('builds p-package route for selected small automatic workplace', () {
    final result = buildOrderStages(
      const OrderStageQueueDraft(
        productTypeId: kPTypePackageProduct,
        orderWidthB: 600,
        materialWidth: 600,
        hasPaint: false,
        hasTrimming: true,
        hasCardboard: true,
        handleType: OrderHandleType.twisted,
        selectedSwitchableStageIdsByStageKey: {
          kPMainSwitchStageKey: kAutoSmallStageId,
        },
      ),
    );

    final switchStage = result.first;
    final handleStage = result.singleWhere(
      (stage) => stage.stageKey == kTwistedHandleGroupStageId,
    );

    expect(
      result.map((stage) => stage.stageKey),
      [
        kPMainSwitchStageKey,
        kCuttingStageId,
        kCardboardCuttingStageId,
        kCardboardInsertStageId,
        kTwistedHandleGroupStageId,
        kPackagingStageId,
      ],
    );
    expect(switchStage.stageName, 'Автомат маленький');
    expect(switchStage.selectedWorkplaceId, kAutoSmallStageId);
    expect(
      result.map((stage) => stage.stageKey),
      isNot(contains(kBottomWithCardboardAssemblyStageId)),
    );
    expect(
      result.map((stage) => stage.stageKey),
      isNot(contains(kBottomGlueStageId)),
    );
    expect(handleStage.workplaceIds, [
      kTwistedHandleStageId,
      kManualHandleStageId,
    ]);
  });

  test('builds p-package route for selected tube workplace', () {
    final result = buildOrderStages(
      const OrderStageQueueDraft(
        productTypeId: kPTypePackageProduct,
        orderWidthB: 600,
        materialWidth: 600,
        hasPaint: false,
        hasTrimming: true,
        hasCardboard: true,
        handleType: OrderHandleType.dieCut,
        selectedSwitchableStageId: kTubeStageId,
      ),
    );

    final switchStage = result.first;
    final bottomGlueStage = result.singleWhere(
      (stage) => stage.stageKey == kBottomGlueStageId,
    );

    expect(
      result.map((stage) => stage.stageKey),
      [
        kPMainSwitchStageKey,
        kCuttingStageId,
        kCardboardCuttingStageId,
        kBottomWithCardboardAssemblyStageId,
        kBottomGlueStageId,
        kDieCutHandleStageId,
        kPackagingStageId,
      ],
    );
    expect(switchStage.stageName, 'Труба');
    expect(switchStage.selectedWorkplaceId, kTubeStageId);
    expect(
      result.map((stage) => stage.stageKey),
      isNot(contains(kCardboardInsertStageId)),
    );
    expect(bottomGlueStage.workplaceIds, [
      kBottomGlueWorkplaceId,
      kBottomGlueAltWorkplaceId,
      kBottomGlueSecondAltWorkplaceId,
    ]);
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


  group('comprehensive production routes', () {
    test('Листы: no options keeps only sheet cutting and packaging', () {
      final result = buildOrderStages(
        const OrderStageQueueDraft(
          productTypeId: kSheetProductTypeId,
          orderWidthB: 600,
          materialWidth: 600,
          hasPaint: false,
          hasTrimming: false,
          hasCardboard: false,
        ),
      );

      expectBuiltStages(result, [kSheetCutStageId, kPackagingStageId]);
    });

    test('Листы: adds Бабинорезка when product width is smaller', () {
      final result = buildOrderStages(
        const OrderStageQueueDraft(
          productTypeId: 'Листы',
          orderWidthB: 300,
          materialWidth: 600,
          hasPaint: false,
          hasTrimming: false,
          hasCardboard: false,
        ),
      );

      expectBuiltStages(result, [
        kBobbinStageId,
        kSheetCutStageId,
        kPackagingStageId,
      ]);
    });

    test('Листы: adds Флексопечать between Бабинорезка and Листорезка', () {
      final result = buildOrderStages(
        const OrderStageQueueDraft(
          productTypeId: 'Листы',
          orderWidthB: 300,
          materialWidth: 600,
          hasPaint: true,
          hasTrimming: false,
          hasCardboard: false,
        ),
      );

      expectBuiltStages(result, [
        kBobbinStageId,
        kFlexPrintingStageId,
        kSheetCutStageId,
        kPackagingStageId,
      ]);
    });

    test('Листы: adds Подрезка after Листорезка', () {
      final result = buildOrderStages(
        const OrderStageQueueDraft(
          productTypeId: 'Листы',
          orderWidthB: 600,
          materialWidth: 600,
          hasPaint: false,
          hasTrimming: true,
          hasCardboard: false,
        ),
      );

      expectBuiltStages(result, [
        kSheetCutStageId,
        kCuttingStageId,
        kPackagingStageId,
      ]);
    });

    test('Листы: ignores disabled cardboard branch even when flag is true', () {
      final result = buildOrderStages(
        const OrderStageQueueDraft(
          productTypeId: 'Листы',
          orderWidthB: 600,
          materialWidth: 600,
          hasPaint: false,
          hasTrimming: false,
          hasCardboard: true,
        ),
      );

      expect(supportsCardboardForProductType('Листы'), isFalse);
      expectBuiltStages(result, [kSheetCutStageId, kPackagingStageId]);
      expect(
        result.map((stage) => stage.stageKey),
        isNot(contains(kCardboardCuttingStageId)),
      );
    });

    test('В-образные UUID products default to Фри and disable cardboard', () {
      for (final productTypeId in kVTypeProducts) {
        final result = buildOrderStages(
          OrderStageQueueDraft(
            productTypeId: productTypeId,
            orderWidthB: 600,
            materialWidth: 600,
            hasPaint: false,
            hasTrimming: false,
            hasCardboard: true,
          ),
        );

        expect(supportsCardboardForProductType(productTypeId), isFalse);
        expectBuiltStages(
          result,
          [kVMainSwitchStageKey, kPackagingStageId],
          workplaceIdsByStageKey: const {
            kVMainSwitchStageKey: [kFriStageId, kWindowStageId],
          },
          selectedWorkplaceIdsByStageKey: const {
            kVMainSwitchStageKey: kFriStageId,
          },
        );
        expect(result.first.stageName, 'Фри');
        expect(result.first.isSwitchable, isTrue);
        expect(result.first.switchableGroupKey, kSwitchableVGroupKey);
        expect(
          result.map((stage) => stage.stageKey),
          isNot(contains(kCardboardCuttingStageId)),
        );
      }
    });

    test('В-образный: switches from Фри to Окно', () {
      final result = buildOrderStages(
        const OrderStageQueueDraft(
          productTypeId: kVTypeProductId,
          orderWidthB: 600,
          materialWidth: 600,
          hasPaint: false,
          hasTrimming: false,
          hasCardboard: false,
          selectedSwitchableStageIdsByStageKey: {
            kVMainSwitchStageKey: kWindowStageId,
          },
        ),
      );

      expectBuiltStages(
        result,
        [kVMainSwitchStageKey, kPackagingStageId],
        workplaceIdsByStageKey: const {
          kVMainSwitchStageKey: [kFriStageId, kWindowStageId],
        },
        selectedWorkplaceIdsByStageKey: const {
          kVMainSwitchStageKey: kWindowStageId,
        },
      );
      expect(result.first.stageName, 'Окно');
    });

    test('В-образный: adds Подрезка after selected bottom stage', () {
      final result = buildOrderStages(
        const OrderStageQueueDraft(
          productTypeId: kVTypeProductAltId,
          orderWidthB: 600,
          materialWidth: 600,
          hasPaint: false,
          hasTrimming: true,
          hasCardboard: false,
        ),
      );

      expectBuiltStages(
        result,
        [kVMainSwitchStageKey, kCuttingStageId, kPackagingStageId],
        workplaceIdsByStageKey: const {
          kVMainSwitchStageKey: [kFriStageId, kWindowStageId],
        },
        selectedWorkplaceIdsByStageKey: const {
          kVMainSwitchStageKey: kFriStageId,
        },
      );
    });

    test('Пакет из 2х листов: full route with optional trimming/cardboard', () {
      final result = buildOrderStages(
        const OrderStageQueueDraft(
          productTypeId: kTwoSheetPackageProductTypeId,
          orderWidthB: 600,
          materialWidth: 600,
          hasPaint: false,
          hasTrimming: true,
          hasCardboard: true,
          handleType: OrderHandleType.flat,
        ),
      );

      expectBuiltStages(
        result,
        [
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
        workplaceIdsByStageKey: const {
          kDieCutA1A2StageId: [kDieCutA1WorkplaceId, kDieCutA2WorkplaceId],
          kBottomGlueStageId: [
            kBottomGlueWorkplaceId,
            kBottomGlueAltWorkplaceId,
            kBottomGlueSecondAltWorkplaceId,
          ],
          kFlatHandleGroupStageId: [
            kFlatHandleStageId,
            kManualHandleStageId,
          ],
        },
      );
    });

    test('Пакет из 2х листов: trimming/cardboard are optional', () {
      final result = buildOrderStages(
        const OrderStageQueueDraft(
          productTypeId: kTwoSheetPackageProductTypeId,
          orderWidthB: 600,
          materialWidth: 600,
          hasPaint: false,
          hasTrimming: false,
          hasCardboard: false,
          handleType: OrderHandleType.dieCut,
        ),
      );

      expectBuiltStages(result, [
        kSheetCutStageId,
        kDieCutA1A2StageId,
        kScotchStageId,
        kFromTwoSheetsStageId,
        kTubeAssemblyStageId,
        kBottomWithCardboardAssemblyStageId,
        kBottomGlueStageId,
        kDieCutHandleStageId,
        kPackagingStageId,
      ]);
      expect(
        result.map((stage) => stage.stageKey),
        isNot(contains(kCuttingStageId)),
      );
      expect(
        result.map((stage) => stage.stageKey),
        isNot(contains(kCardboardCuttingStageId)),
      );
    });

    test('Пакет из 2х листов: supports twisted handles', () {
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

      expectBuiltStages(
        result,
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
        workplaceIdsByStageKey: const {
          kTwistedHandleGroupStageId: [
            kTwistedHandleStageId,
            kManualHandleStageId,
          ],
        },
      );
    });

    test('П-образный пакет: Автомат большой uses cardboard insert branch', () {
      final queue = buildOrderStageQueue(
        productTypeId: kPTypePackageProduct,
        hasCutting: true,
        hasCardboard: true,
        hasFlexPrinting: false,
        handleType: OrderHandleType.flat,
        selectedSwitchableStageIdsByStageKey: const {
          kPMainSwitchStageKey: kAutoBigStageId,
        },
      );

      expectQueueMaps(
        queue,
        [
          kPMainSwitchStageKey,
          kCuttingStageId,
          kCardboardCuttingStageId,
          kCardboardInsertStageId,
          kFlatHandleGroupStageId,
          kPackagingStageId,
        ],
        workplaceIdsByStageKey: const {
          kPMainSwitchStageKey: [
            kAutoBigStageId,
            kAutoSmallStageId,
            kTubeStageId,
          ],
          kFlatHandleGroupStageId: [
            kFlatHandleStageId,
            kManualHandleStageId,
          ],
        },
        selectedWorkplaceIdsByStageKey: const {
          kPMainSwitchStageKey: kAutoBigStageId,
        },
      );
      expect(queue.first['stageName'], 'Автомат большой');
      expect(queue.first['isSwitchable'], isTrue);
      expect(queue.first['switchableGroupKey'], kSwitchablePGroupKey);
      expect(
        queue.map((stage) => stage['stageKey']),
        isNot(contains(kBottomGlueStageId)),
      );
    });

    test('П-образный пакет: Автомат маленький uses same cardboard branch', () {
      final queue = buildOrderStageQueue(
        productTypeId: kPTypePackageProduct,
        hasCutting: true,
        hasCardboard: true,
        hasFlexPrinting: false,
        handleType: OrderHandleType.twisted,
        selectedSwitchableStageIdsByStageKey: const {
          kPMainSwitchStageKey: kAutoSmallStageId,
        },
      );

      expectQueueMaps(
        queue,
        [
          kPMainSwitchStageKey,
          kCuttingStageId,
          kCardboardCuttingStageId,
          kCardboardInsertStageId,
          kTwistedHandleGroupStageId,
          kPackagingStageId,
        ],
        workplaceIdsByStageKey: const {
          kPMainSwitchStageKey: [
            kAutoBigStageId,
            kAutoSmallStageId,
            kTubeStageId,
          ],
          kTwistedHandleGroupStageId: [
            kTwistedHandleStageId,
            kManualHandleStageId,
          ],
        },
        selectedWorkplaceIdsByStageKey: const {
          kPMainSwitchStageKey: kAutoSmallStageId,
        },
      );
      expect(queue.first['stageName'], 'Автомат маленький');
    });

    test('П-образный пакет: Труба uses bottom cardboard/glue branch', () {
      final queue = buildOrderStageQueue(
        productTypeId: kPTypePackageProduct,
        hasCutting: true,
        hasCardboard: true,
        hasFlexPrinting: false,
        handleType: OrderHandleType.dieCut,
        selectedSwitchableStageIdsByStageKey: const {
          kPMainSwitchStageKey: kTubeStageId,
        },
      );

      expectQueueMaps(
        queue,
        [
          kPMainSwitchStageKey,
          kCuttingStageId,
          kCardboardCuttingStageId,
          kBottomWithCardboardAssemblyStageId,
          kBottomGlueStageId,
          kDieCutHandleStageId,
          kPackagingStageId,
        ],
        workplaceIdsByStageKey: const {
          kPMainSwitchStageKey: [
            kAutoBigStageId,
            kAutoSmallStageId,
            kTubeStageId,
          ],
          kBottomGlueStageId: [
            kBottomGlueWorkplaceId,
            kBottomGlueAltWorkplaceId,
            kBottomGlueSecondAltWorkplaceId,
          ],
        },
        selectedWorkplaceIdsByStageKey: const {
          kPMainSwitchStageKey: kTubeStageId,
        },
      );
      expect(queue.first['stageName'], 'Труба');
      expect(
        queue.map((stage) => stage['stageKey']),
        isNot(contains(kCardboardInsertStageId)),
      );
    });

    test('П-образный пакет: cardboard branch is optional for switches', () {
      final result = buildOrderStages(
        const OrderStageQueueDraft(
          productTypeId: kPTypePackageProduct,
          orderWidthB: 600,
          materialWidth: 600,
          hasPaint: false,
          hasTrimming: false,
          hasCardboard: false,
          handleType: OrderHandleType.flat,
          selectedSwitchableStageId: kTubeStageId,
        ),
      );

      expectBuiltStages(
        result,
        [kPMainSwitchStageKey, kFlatHandleGroupStageId, kPackagingStageId],
        workplaceIdsByStageKey: const {
          kPMainSwitchStageKey: [
            kAutoBigStageId,
            kAutoSmallStageId,
            kTubeStageId,
          ],
          kFlatHandleGroupStageId: [
            kFlatHandleStageId,
            kManualHandleStageId,
          ],
        },
        selectedWorkplaceIdsByStageKey: const {
          kPMainSwitchStageKey: kTubeStageId,
        },
      );
      expect(
        result.map((stage) => stage.stageKey),
        isNot(contains(kCardboardCuttingStageId)),
      );
    });
  });

}
