import 'package:flutter_test/flutter_test.dart';
import 'package:sheet_clone/modules/personnel/workplace_model.dart';

/// Признак «делить количество по времени» решает, получит участник свою долю
/// или полный тираж. Ошибка в разборе — это ошибка в зарплате, поэтому
/// проверяется и значение по умолчанию, и оба варианта написания ключа.
void main() {
  Map<String, dynamic> base(Map<String, dynamic> extra) => <String, dynamic>{
        'name': 'Тестовое РМ',
        'positionIds': const <String>[],
        ...extra,
      };

  group('WorkplaceModel.splitQuantityByTime', () {
    test('по умолчанию делим по времени', () {
      // Пока миграция не применена, колонки в ответе нет. Рабочее место
      // обязано вести себя как обычное, а не как станок.
      final w = WorkplaceModel.fromMap(base(const {}), 'wp-1');
      expect(w.splitQuantityByTime, isTrue);
    });

    test('false читается из snake_case', () {
      final w =
          WorkplaceModel.fromMap(base({'split_quantity_by_time': false}), 'wp-1');
      expect(w.splitQuantityByTime, isFalse);
    });

    test('false читается из camelCase', () {
      final w =
          WorkplaceModel.fromMap(base({'splitQuantityByTime': false}), 'wp-1');
      expect(w.splitQuantityByTime, isFalse);
    });

    test('не теряется при сохранении и повторном чтении', () {
      final source = WorkplaceModel(
        id: 'wp-1',
        name: 'Флексопечать',
        positionIds: const <String>[],
        splitQuantityByTime: false,
      );
      final restored = WorkplaceModel.fromMap(source.toMap(), source.id);
      expect(restored.splitQuantityByTime, isFalse);
    });

    test('булево строкой разбирается, а не роняет справочник', () {
      // Драйвер может отдать булево строкой. Приведение as bool? бросало
      // исключение и валило загрузку ВСЕГО списка рабочих мест.
      expect(
        WorkplaceModel.fromMap(
                base({'split_quantity_by_time': 'false'}), 'wp-1')
            .splitQuantityByTime,
        isFalse,
      );
      expect(
        WorkplaceModel.fromMap(base({'split_quantity_by_time': 't'}), 'wp-1')
            .splitQuantityByTime,
        isTrue,
      );
    });

    test('непонятное значение трактуется как обычное рабочее место', () {
      // Выключить деление молча — значит выдать каждому участнику полный
      // тираж. Из двух ошибок безопаснее делить.
      final w = WorkplaceModel.fromMap(
          base({'split_quantity_by_time': 'наверное'}), 'wp-1');
      expect(w.splitQuantityByTime, isTrue);
    });
  });
}
