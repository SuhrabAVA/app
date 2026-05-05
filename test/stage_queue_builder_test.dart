import 'package:flutter_test/flutter_test.dart';
import 'package:sheet_clone/modules/orders/stage_queue_builder.dart';

void main() {
  test('inserts product stage after bobbin/flexo base stages', () {
    final queue = [
      {'stageId': 'b92a89d1-8e95-4c6d-b990-e308486e4bf1', 'stageName': 'Бобинорезка'},
      {'stageId': '0571c01c-f086-47e4-81b2-5d8b2ab91218', 'stageName': 'Флексопечать'},
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
}
