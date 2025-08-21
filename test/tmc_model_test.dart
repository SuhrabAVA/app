import 'package:flutter_test/flutter_test.dart';
import 'package:sheet_clone/modules/warehouse/tmc_model.dart';

void main() {
  test('TmcModel serializes new paper fields', () {
    final model = TmcModel(
      id: '1',
      date: '2024-01-01',
      type: 'Бумага',
      description: 'Тест',
      quantity: 10,
      unit: 'м',
      format: 'A4',
      grammage: '80',
      weight: 5,
    );
    final map = model.toMap();
    expect(map['format'], 'A4');
    expect(map['grammage'], '80');
    expect(map['weight'], 5);
    final decoded = TmcModel.fromMap(map);
    expect(decoded.format, 'A4');
    expect(decoded.grammage, '80');
    expect(decoded.weight, 5);
  });
}
