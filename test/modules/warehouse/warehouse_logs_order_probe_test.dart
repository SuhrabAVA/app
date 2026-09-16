import 'package:flutter_test/flutter_test.dart';
import 'package:sheet_clone/modules/warehouse/warehouse_logs_repository.dart';

void main() {
  group('isMissingOrderColumnMessage', () {
    test('узнаёт отсутствующую колонку сортировки', () {
      expect(
        WarehouseLogsRepository.isMissingOrderColumnMessage(
            'column papers.description does not exist', 'description'),
        isTrue,
      );
      expect(
        WarehouseLogsRepository.isMissingOrderColumnMessage(
            'column "title" does not exist', 'title'),
        isTrue,
      );
    });

    test('нехватка колонки из select — не повод менять сортировку', () {
      // Живой случай: select с full_name, сортировка по name. Раньше код 42703
      // засчитывался как «нет колонки сортировки», и цикл делал шесть
      // заведомо ошибочных запросов.
      expect(
        WarehouseLogsRepository.isMissingOrderColumnMessage(
            'column employees_view.full_name does not exist', 'name'),
        isFalse,
      );
      expect(
        WarehouseLogsRepository.isMissingOrderColumnMessage(
            'column orders.title does not exist', 'id'),
        isFalse,
      );
    });

    test('ошибка не про колонку', () {
      expect(
        WarehouseLogsRepository.isMissingOrderColumnMessage(
            'relation "public.paper_writeoffs" does not exist', 'description'),
        isFalse,
      );
    });
  });
}
