import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sheet_clone/modules/analytics/models/salary_adjustments.dart';
import 'package:sheet_clone/modules/analytics/services/analytics_permission_service.dart';
import 'package:sheet_clone/modules/analytics/widgets/employees_table.dart';

import 'analytics_test_fixtures.dart';

/// Записывающий сервис: перехватывает saveSalaryAdjustments, чтобы проверить
/// инлайн-редактирование финансовых колонок (Фаза B).
class _RecordingService extends FakeAnalyticsService {
  _RecordingService(super.fixed);

  final List<SalaryAdjustments> saved = [];

  @override
  Future<void> saveSalaryAdjustments(SalaryAdjustments adj,
      {String? actorId}) async {
    saved.add(adj);
  }
}

void main() {
  final techLeader = AnalyticsPermissionService(
    isTechLeader: true,
    currentEmployeeId: 'e1',
  );

  // Широкий вьюпорт: финансовые колонки (инпуты) уходят далеко вправо;
  // при 1600px они за пределами видимой области (ClipRect) и не хиттестятся.
  // При 3400px restWidth (=maxWidth-300) укладывается целиком, offset 0 —
  // все инпуты на экране и доступны для tap/enterText.
  Future<void> pumpTable(
    WidgetTester tester,
    _RecordingService service, {
    ValueChanged<String>? onTap,
  }) async {
    tester.view.physicalSize = const Size(3400, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          body: SingleChildScrollView(
            child: EmployeesTable(
              service: service,
              personnel: mockPersonnel(),
              permission: techLeader,
              onEmployeeTap: onTap ?? (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('таблица содержит колонку «Смены» и 6 редактируемых '
      'финансовых полей на строку', (tester) async {
    final service = _RecordingService(mockState());
    await pumpTable(tester, service);

    // Заголовок новой колонки (label в шапке — в верхнем регистре).
    expect(find.text('СМЕНЫ'), findsOneWidget);
    // Заголовки-этолоны финансовых колонок.
    expect(find.text('СДЕЛЬНО / ОКЛАД'), findsOneWidget);
    expect(find.text('ОПЛАТА НОЧНЫХ'), findsOneWidget);

    // 6 инлайн-инпутов (Компенсация, Соц., Аванс, ЗП безнал, Дисциплина,
    // Браки) × 3 сотрудника = 18 полей.
    expect(find.byType(TextField), findsNWidgets(18));
  });

  testWidgets('ввод в поле сохраняется по Enter (не на каждый символ)',
      (tester) async {
    final service = _RecordingService(mockState());
    await pumpTable(tester, service);

    // Первое поле в дереве — «Компенсация» первой строки (e1 — Иванов).
    final field = find.byType(TextField).first;
    await tester.enterText(field, '500');
    // Пока не подтвердили — сохранения нет (не спамим на каждый символ).
    expect(service.saved, isEmpty);

    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    expect(service.saved, hasLength(1));
    expect(service.saved.first.compensation, 500);
  });

  testWidgets('клик по активному инпуту НЕ открывает деталку сотрудника',
      (tester) async {
    String? tapped;
    final service = _RecordingService(mockState());
    await pumpTable(tester, service, onTap: (id) => tapped = id);

    await tester.tap(find.byType(TextField).first);
    await tester.pump();

    expect(tapped, isNull,
        reason: 'тап по инпуту не должен всплывать до InkWell строки');
  });

  testWidgets('клик по обычной ячейке строки открывает деталку',
      (tester) async {
    String? tapped;
    final service = _RecordingService(mockState());
    await pumpTable(tester, service, onTap: (id) => tapped = id);

    await tester.tap(find.text('Иванов Иван'));
    await tester.pump();

    expect(tapped, 'e1');
  });

  testWidgets(
      'чип «Сдельно/оклад»: окладник (e2, base>0) → «Оклад», '
      'сдельщик (e1) → «Сдельно»', (tester) async {
    final service = _RecordingService(mockState());
    await pumpTable(tester, service);

    // e2 — окладник (payType salary, base 16000) → чип «Оклад».
    expect(find.textContaining('Оклад:'), findsWidgets);
    // e1 — сдельщик (payType piece, есть выработка) → чип «Сдельно».
    expect(find.textContaining('Сдельно:'), findsOneWidget);
  });
}
