import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sheet_clone/modules/personnel/employee_attendance_repository.dart';
import 'package:sheet_clone/modules/personnel/status_shift_screen.dart';
import 'package:sheet_clone/utils/shift_day.dart';

/// Репозиторий-заглушка: держит одну отметку в памяти и повторяет правила
/// боевого (повторный приход не сдвигает время, уход без прихода его
/// проставляет).
class _FakeAttendanceRepository implements EmployeeAttendanceRepository {
  EmployeeAttendanceDay? day;
  int arrivals = 0;
  int departures = 0;

  @override
  Future<void> markArrival({required String employeeId, DateTime? at}) async {
    arrivals++;
    final moment = at ?? DateTime.now();
    final current = day;
    if (current?.arrivedAt != null && current?.leftAt == null) return;
    day = EmployeeAttendanceDay(
      employeeId: employeeId,
      workDate: shiftDayOf(moment),
      arrivedAt: moment,
    );
  }

  @override
  Future<void> markDeparture({required String employeeId, DateTime? at}) async {
    departures++;
    final moment = at ?? DateTime.now();
    day = EmployeeAttendanceDay(
      employeeId: employeeId,
      workDate: shiftDayOf(moment),
      arrivedAt: day?.arrivedAt ?? moment,
      leftAt: moment,
    );
  }

  @override
  Future<EmployeeAttendanceDay?> loadDay({
    required String employeeId,
    required DateTime workDate,
  }) async =>
      day;

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('isStatusOnlyEmployee', () {
    test('статус без должности — да', () {
      expect(
        isStatusOnlyEmployee(positionIds: const [], statusId: 'guard'),
        isTrue,
      );
    });

    test('должность есть — нет, даже со статусом', () {
      expect(
        isStatusOnlyEmployee(positionIds: const ['operator'], statusId: 'trainee'),
        isFalse,
      );
    });

    test('без статуса — нет', () {
      expect(isStatusOnlyEmployee(positionIds: const [], statusId: null), isFalse);
      expect(isStatusOnlyEmployee(positionIds: const [], statusId: '  '), isFalse);
    });

    test('пустые строки должностей не считаются должностью', () {
      expect(
        isStatusOnlyEmployee(positionIds: const ['', '  '], statusId: 'guard'),
        isTrue,
      );
    });
  });

  group('StatusShiftScreen', () {
    Future<_FakeAttendanceRepository> pump(WidgetTester tester) async {
      final repo = _FakeAttendanceRepository();
      await tester.pumpWidget(MaterialApp(
        home: StatusShiftScreen(
          employeeId: 'e1',
          employeeName: 'Иванов Иван',
          statusName: 'Охранник',
          repository: repo,
        ),
      ));
      await tester.pumpAndSettle();
      return repo;
    }

    bool enabled(WidgetTester tester, Key key) =>
        tester.widget<ButtonStyleButton>(find.byKey(key)).onPressed != null;

    testWidgets('до отметки активна только кнопка «Пришёл»', (tester) async {
      await pump(tester);

      expect(find.text('Смена не начата'), findsOneWidget);
      expect(find.text('Охранник'), findsOneWidget);

      expect(enabled(tester, arriveButtonKey), isTrue);
      expect(enabled(tester, leaveButtonKey), isFalse,
          reason: 'уйти, не придя, нельзя');
    });

    testWidgets('приход переводит смену в «На смене»', (tester) async {
      final repo = await pump(tester);

      await tester.tap(find.byKey(arriveButtonKey));
      await tester.pumpAndSettle();

      expect(repo.arrivals, 1);
      expect(repo.day?.arrivedAt, isNotNull);
      expect(find.text('На смене'), findsOneWidget);
      expect(enabled(tester, arriveButtonKey), isFalse,
          reason: 'повторный приход не нужен');
      expect(enabled(tester, leaveButtonKey), isTrue);
    });

    testWidgets('уход завершает смену', (tester) async {
      final repo = await pump(tester);

      await tester.tap(find.byKey(arriveButtonKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(leaveButtonKey));
      await tester.pumpAndSettle();

      expect(repo.departures, 1);
      expect(repo.day?.leftAt, isNotNull);
      expect(find.text('Смена завершена'), findsOneWidget);
    });

    testWidgets('на экране сказано, что отметка не влияет на зарплату',
        (tester) async {
      await pump(tester);
      expect(
        find.textContaining('На зарплату она не влияет'),
        findsOneWidget,
      );
    });
  });
}
