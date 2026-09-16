import 'package:flutter_test/flutter_test.dart';
import 'package:sheet_clone/modules/analytics/models/employee_status_period.dart';
import 'package:sheet_clone/utils/shift_day.dart';

/// Граница смены и границы периодов статуса обязаны совпадать: день на стыке
/// иначе будет оплачен по одному правилу, а посчитан по другому.
void main() {
  group('shiftDayOf', () {
    test('дневное время относится к своим суткам', () {
      expect(shiftDayOf(DateTime(2026, 8, 12, 14, 30)), DateTime(2026, 8, 12));
      expect(shiftDayOf(DateTime(2026, 8, 12, 6)), DateTime(2026, 8, 12));
    });

    test('до 06:00 — смена предыдущего дня', () {
      expect(shiftDayOf(DateTime(2026, 8, 13, 2, 15)), DateTime(2026, 8, 12));
      expect(shiftDayOf(DateTime(2026, 8, 13, 5, 59)), DateTime(2026, 8, 12));
    });

    test('переход через начало месяца', () {
      expect(shiftDayOf(DateTime(2026, 9, 1, 3)), DateTime(2026, 8, 31));
    });
  });

  group('nextShiftDayAfter', () {
    test('правка днём — граница завтра', () {
      expect(
        nextShiftDayAfter(DateTime(2026, 8, 12, 14, 0)),
        DateTime(2026, 8, 13),
      );
    });

    test('правка ночью до 06:00 не отнимает текущую ночную смену', () {
      // 13.08 02:00 — это ещё смена 12.08, поэтому новый период с 13.08.
      expect(
        nextShiftDayAfter(DateTime(2026, 8, 13, 2, 0)),
        DateTime(2026, 8, 13),
      );
    });
  });

  group('период статуса на границе', () {
    test('день снятия статуса целиком остаётся под статусом', () {
      final boundary = nextShiftDayAfter(DateTime(2026, 8, 12, 14, 0));
      final period = EmployeeStatusPeriod(
        statusId: 'trainee',
        dateFrom: DateTime(2026, 8, 1),
        dateTo: boundary,
      );

      // Смена, в середине которой сняли статус, ещё под статусом.
      expect(period.covers(DateTime(2026, 8, 12)), isTrue);
      // Сдельная начинается со следующей смены.
      expect(period.covers(DateTime(2026, 8, 13)), isFalse);
    });

    test('новый период подхватывает ровно со следующего дня', () {
      final boundary = nextShiftDayAfter(DateTime(2026, 8, 12, 23, 30));
      final opened = EmployeeStatusPeriod(
        statusId: 'guard',
        dateFrom: boundary,
      );

      expect(opened.covers(DateTime(2026, 8, 12)), isFalse);
      expect(opened.covers(DateTime(2026, 8, 13)), isTrue);
    });
  });
}
