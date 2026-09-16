import 'package:flutter_test/flutter_test.dart';
import 'package:sheet_clone/modules/warehouse/paper_multi_filter.dart';

void main() {
  group('PaperMultiFilter.matches', () {
    test('пустой фильтр пропускает всё', () {
      final filter = PaperMultiFilter();
      expect(filter.isActive, isFalse);
      expect(filter.matches(name: 'китс 7', format: '84', grammage: '40'),
          isTrue);
    });

    test('списание отбирается по названию, формату и граммажу', () {
      // Живой случай: журнал списаний бумаги, фильтр «китс 7 / 84 / 40».
      final filter = PaperMultiFilter()
        ..names.add('китс 7')
        ..formats.add('84')
        ..grammages.add('40');

      expect(filter.matches(name: 'китс 7', format: '84', grammage: '40'),
          isTrue);
      expect(filter.matches(name: 'МЦБК', format: '84', grammage: '40'),
          isFalse);
      expect(filter.matches(name: 'китс 7', format: '72', grammage: '40'),
          isFalse);
      expect(filter.matches(name: 'китс 7', format: '84', grammage: '45'),
          isFalse);
    });

    test('лишние пробелы и регистр не мешают', () {
      // Словарь строился из обрезанных строк, а сравнение шло дословно:
      // рулон «Подпергамент белый аснова » не находился никогда.
      final filter = PaperMultiFilter()..names.add('Подпергамент белый аснова');
      expect(filter.matches(name: 'подпергамент  белый аснова '), isTrue);
    });

    test('формат и граммаж сравниваются как числа', () {
      final filter = PaperMultiFilter()
        ..formats.add('24,5')
        ..grammages.add('40');
      expect(filter.matches(name: 'ВП', format: '24.5', grammage: '40.0'),
          isTrue);
      expect(filter.matches(name: 'ВП', format: '245', grammage: '40'),
          isFalse);
    });

    test('без формата запись не проходит фильтр по формату', () {
      final filter = PaperMultiFilter()..formats.add('84');
      expect(filter.matches(name: 'китс 7', format: null), isFalse);
      expect(filter.matches(name: 'китс 7', format: ''), isFalse);
    });

    test('несколько значений в группе — любое из них', () {
      final filter = PaperMultiFilter()..names.addAll(['китс 7', 'МЦБК']);
      expect(filter.matches(name: 'МЦБК'), isTrue);
      expect(filter.matches(name: 'ВП'), isFalse);
    });

    test('сброс снимает все группы', () {
      final filter = PaperMultiFilter()
        ..names.add('китс 7')
        ..formats.add('84');
      expect(filter.selectedCount, 2);
      filter.clear();
      expect(filter.isActive, isFalse);
    });
  });

  group('PaperFilterOptions', () {
    test('варианты без повторов, форматы по величине', () {
      final options = PaperFilterOptions.from([
        (name: 'китс 7', format: '84', grammage: '40'),
        (name: 'китс 7 ', format: '84.0', grammage: '40'),
        (name: 'МЦБК', format: '102', grammage: '80'),
        (name: 'ВП', format: '24,5', grammage: null),
        (name: '', format: '', grammage: ''),
      ]);
      expect(options.names, ['ВП', 'китс 7', 'МЦБК']);
      expect(options.formats, ['24,5', '84', '102']);
      expect(options.grammages, ['40', '80']);
    });
  });
}
