import 'package:flutter_test/flutter_test.dart';
import 'package:sheet_clone/modules/tasks/stage_sequence_utils.dart';

void main() {
  test('normalizeStageSequence removes mirrored duplicate tail', () {
    final normalized = normalizeStageSequence(['a', 'b', 'c', 'c', 'b', 'a']);
    expect(normalized, ['a', 'b', 'c']);
  });

  test('normalizeStageSequence keeps first occurrence order', () {
    final normalized = normalizeStageSequence(['  a ', 'b', 'a', '', 'c', 'b']);
    expect(normalized, ['a', 'b', 'c']);
  });
}
