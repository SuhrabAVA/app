import 'package:flutter_test/flutter_test.dart';
import 'package:sheet_clone/modules/orders/edit_order_screen.dart';
import 'package:sheet_clone/modules/orders/stage_queue_builder.dart';

void main() {
  group('production plan save stage maps', () {
    test(
      'creates product-type queue without selected template and ends with packaging',
      () {
        List<Map<String, dynamic>>? receivedTemplateStages;

        final stageMaps = buildStageMapsForProductionPlanSaveForTesting(
          stagePreviewStages: const <Map<String, dynamic>>[],
          stageTemplateId: '',
          selectedTemplateStages: const <Map<String, dynamic>>[
            {
              'stageKey': kPMainSwitchStageKey,
              'stageId': kTubeStageId,
              'selectedWorkplaceId': kTubeStageId,
              'stageName': 'Труба',
            },
          ],
          buildStageQueueFromCurrentDraft: ({required templateStages}) {
            receivedTemplateStages = templateStages;
            return buildOrderStageQueue(
              productTypeId: kPTypePackageProduct,
              hasCutting: true,
              hasCardboard: true,
              hasFlexPrinting: false,
              templateStages: templateStages,
            );
          },
        );

        expect(receivedTemplateStages, isEmpty);
        expect(
          stageMaps.map((stage) => stage['stageKey']),
          [
            kPMainSwitchStageKey,
            kCuttingStageId,
            kCardboardCuttingStageId,
            kCardboardInsertStageId,
            kPackagingStageId,
          ],
        );
        expect(stageMaps.first['stageName'], 'Автомат большой');
        expect(stageMaps.last['stageName'], 'Упаковка');
      },
    );
  });

  group('supportsCardboardForTesting', () {
    test('returns false for sheet and V-type products', () {
      expect(supportsCardboardForTesting(kSheetProductTypeId), isFalse);

      for (final productTypeId in kVTypeProducts) {
        expect(
          supportsCardboardForTesting(productTypeId),
          isFalse,
          reason: 'V-type product $productTypeId should not support cardboard',
        );
      }
    });

    test('returns true for P-type and two-sheet package products', () {
      expect(supportsCardboardForTesting(kPTypePackageProduct), isTrue);
      expect(supportsCardboardForTesting(kTwoSheetPackageProductTypeId), isTrue);
    });
  });
}
