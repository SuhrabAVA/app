import 'package:flutter_test/flutter_test.dart';

import 'package:sheet_clone/modules/production_planning/planned_stage_model.dart';

void main() {
  test('decodePlannedStages handles list and map structures', () {
    final listData = [
      {'stageId': '1', 'stageName': 'Stage A'},
      {'stageId': '2', 'stageName': 'Stage B', 'comment': 'note'},
    ];

    final mapData = {
      '0': {'stageId': '1', 'stageName': 'Stage A'},
      '1': {'stageId': '2', 'stageName': 'Stage B', 'comment': 'note'},
    };

    final fromList = decodePlannedStages(listData);
    final fromMap = decodePlannedStages(mapData);

    expect(fromList.length, 2);
    expect(fromList[1].comment, 'note');
    expect(fromMap.length, 2);
    expect(fromMap[1].comment, 'note');
  });
}