import 'package:flutter_test/flutter_test.dart';
import 'package:sheet_clone/modules/orders/order_stage_filter.dart';

Map<String, dynamic> _stage(String id) => {'stageId': id, 'stageName': id};

void main() {
  final baseStages = [
    _stage(flatHandleStageId),
    _stage(twistedHandleStageId),
    _stage(manualHandleStageId),
    _stage(dieCutHandleStageId),
    _stage(kCardboardCuttingStageId),
    _stage(kCardboardInsertStageId),
    _stage(kBottomWithCardboardAssemblyStageId),
    _stage(cuttingStageId),
    _stage('other-stage'),
  ];

  test('removes optional stages when options disabled', () {
    final filtered = filterOrderStagesByOptions(
      stages: baseStages,
      selectedHandleType: OrderHandleType.none,
      hasCardboard: false,
      hasCutting: false,
    );

    expect(filtered.map((s) => s['stageId']), ['other-stage']);
  });

  test('keeps only twisted handle stage', () {
    final filtered = filterOrderStagesByOptions(
      stages: baseStages,
      selectedHandleType: OrderHandleType.twisted,
      hasCardboard: false,
      hasCutting: false,
    );

    expect(filtered.map((s) => s['stageId']), [
      twistedHandleStageId,
      manualHandleStageId,
      'other-stage',
    ]);
  });

  test('keeps only flat handle stage and enabled flags', () {
    final filtered = filterOrderStagesByOptions(
      stages: baseStages,
      selectedHandleType: OrderHandleType.flat,
      hasCardboard: true,
      hasCutting: true,
    );

    expect(filtered.map((s) => s['stageId']), [
      flatHandleStageId,
      manualHandleStageId,
      kCardboardCuttingStageId,
      kCardboardInsertStageId,
      kBottomWithCardboardAssemblyStageId,
      cuttingStageId,
      'other-stage',
    ]);
  });

  test('keeps die cut handle stage without manual handle stage', () {
    final filtered = filterOrderStagesByOptions(
      stages: baseStages,
      selectedHandleType: OrderHandleType.dieCut,
      hasCardboard: false,
      hasCutting: false,
    );

    expect(filtered.map((s) => s['stageId']), [
      dieCutHandleStageId,
      'other-stage',
    ]);
  });
}
