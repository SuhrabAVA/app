import 'package:flutter_test/flutter_test.dart';
import 'package:sheet_clone/modules/tasks/tasks_screen.dart';

void main() {
  group('parseGramsInput', () {
    test('keeps whole gram values unchanged', () {
      expect(parseGramsInput('1000', checked: true), 1000);
      expect(parseGramsInput('1500', checked: true), 1500);
    });

    test('keeps decimal gram values when interface unit is grams', () {
      expect(parseGramsInput('0.5', checked: true), 0.5);
    });

    test('rejects zero for checked write-off rows', () {
      expect(
        () => parseGramsInput('0', checked: true),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects empty input only for checked write-off rows', () {
      expect(parseGramsInput('', checked: false), isNull);
      expect(
        () => parseGramsInput('', checked: true),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects non-numeric and negative checked values', () {
      expect(
        () => parseGramsInput('abc', checked: true),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => parseGramsInput('-1', checked: true),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
