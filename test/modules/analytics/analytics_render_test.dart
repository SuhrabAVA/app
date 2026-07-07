import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:sheet_clone/modules/analytics/screens/employee_detail_screen.dart';
import 'package:sheet_clone/modules/analytics/screens/employees_analytics_screen.dart';
import 'package:sheet_clone/modules/analytics/screens/workplace_detail_screen.dart';
import 'package:sheet_clone/modules/analytics/screens/workplaces_analytics_screen.dart';
import 'package:sheet_clone/modules/analytics/services/analytics_permission_service.dart';
import 'package:sheet_clone/modules/analytics/widgets/analytics_shell.dart';
import 'package:sheet_clone/modules/analytics/widgets/employees_table.dart';
import 'package:sheet_clone/modules/analytics/widgets/workplaces_table.dart';
import 'package:sheet_clone/modules/personnel/personnel_provider.dart';

import 'analytics_test_fixtures.dart';

/// Рендер-тесты модуля аналитики на десктопном брейкпоинте (1600×900):
/// регрессии на layout-краш деталок (DropdownButton(isExpanded) в Wrap
/// внутри Row, ветка >= 760), сплющенные строки таблиц (нулевая
/// intrinsic-высота StickyScrollArea) и RenderFlex overflow ячеек.
void main() {
  final techLeader = AnalyticsPermissionService(
    isTechLeader: true,
    currentEmployeeId: 'e1',
  );

  /// Ставит десктопный размер окна (сбрасывается в teardown) и перехватывает
  /// FlutterError.onError: overflow приходит именно туда, а не всегда в
  /// takeException. Возвращает накопленные ошибки.
  Future<List<FlutterErrorDetails>> pumpDesktop(
    WidgetTester tester,
    Widget home, {
    Size size = const Size(1600, 900),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final errors = <FlutterErrorDetails>[];
    final prevOnError = FlutterError.onError;
    FlutterError.onError = errors.add;
    try {
      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          home: ChangeNotifierProvider<PersonnelProvider>.value(
            value: mockPersonnel(),
            child: home,
          ),
        ),
      );
      await tester.pumpAndSettle();
    } finally {
      // Восстановить ДО любых expect: упавший expect при переопределённом
      // onError роняет assertion в биндинге и вешает весь прогон.
      FlutterError.onError = prevOnError;
    }
    return errors;
  }

  String describe(List<FlutterErrorDetails> errors) =>
      errors.map((e) => e.exceptionAsString()).join('\n---\n');

  testWidgets('экран «Сотрудники» целиком рендерится без ошибок layout',
      (tester) async {
    final errors = await pumpDesktop(
      tester,
      AnalyticsShell(
        child: EmployeesAnalyticsScreen(
          service: mockService(),
          permission: techLeader,
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(errors, isEmpty, reason: describe(errors));
    expect(find.byType(EmployeesTable), findsOneWidget);
    expect(find.text('Иванов Иван'), findsOneWidget);
  });

  testWidgets('экран «Рабочие места» целиком рендерится без ошибок layout',
      (tester) async {
    final errors = await pumpDesktop(
      tester,
      AnalyticsShell(
        child: WorkplacesAnalyticsScreen(
          service: mockService(),
          permission: techLeader,
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(errors, isEmpty, reason: describe(errors));
    expect(find.byType(WorkplacesTable), findsOneWidget);
  });

  testWidgets(
      'EmployeesTable: сотрудник с тремя РМ (многострочная ячейка) — '
      'без RenderFlex overflow', (tester) async {
    final errors = await pumpDesktop(
      tester,
      Scaffold(
        body: SingleChildScrollView(
          child: EmployeesTable(
            service: mockService(),
            personnel: mockPersonnel(),
            permission: techLeader,
            onEmployeeTap: (_) {},
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(errors, isEmpty, reason: describe(errors));
    // Многострочная ячейка «Рабочие места» у e1 действительно отрисована.
    expect(find.textContaining('Печать:'), findsOneWidget);
    expect(find.textContaining('Ламинация:'), findsOneWidget);
  });

  testWidgets(
      'WorkplacesTable: длинное название РМ с переносом — '
      'без RenderFlex overflow', (tester) async {
    final errors = await pumpDesktop(
      tester,
      Scaffold(
        body: SingleChildScrollView(
          child: WorkplacesTable(
            service: mockService(),
            personnel: mockPersonnel(),
            canEditCoefficient: true,
            onWorkplaceTap: (_) {},
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(errors, isEmpty, reason: describe(errors));
    expect(
      find.textContaining('Полуавтоматическая линия'),
      findsOneWidget,
    );
  });

  testWidgets(
      'деталка сотрудника на ширине >= 760 — без краша '
      '(регрессия: DropdownButton(isExpanded) в Wrap внутри Row)',
      (tester) async {
    final errors = await pumpDesktop(
      tester,
      EmployeeDetailScreen(
        service: mockService(),
        permission: techLeader,
        employeeId: 'e1',
      ),
    );

    expect(tester.takeException(), isNull);
    expect(errors, isEmpty, reason: describe(errors));
    // Контент действительно отрисован, а не пустой фон Scaffold.
    // Имя встречается и в заголовке, и в дропдауне смены сотрудника.
    expect(find.text('Иванов Иван'), findsWidgets);
    expect(find.text('График работы за месяц'), findsOneWidget);
    // Фаза C: новые строки зарплатного блока деталки.
    expect(find.text('Начислено'), findsOneWidget);
    expect(find.text('КПД'), findsOneWidget);
    // Подписи «Ночные N × X%» и «Питание N порц. × цена».
    expect(find.textContaining('Ночные '), findsWidgets);
    expect(find.textContaining('порц. ×'), findsWidgets);
    // Фаза D: окладная строка, тип оплаты и редактируемая ставка.
    expect(find.text('Оклад за смены'), findsOneWidget);
    expect(find.textContaining('Тип оплаты'), findsOneWidget);
    expect(find.text('Ставка оклада (за смену)'), findsOneWidget);
  });

  testWidgets(
      'деталка рабочего места на ширине >= 760 — без краша '
      '(регрессия: DropdownButton(isExpanded) в Wrap внутри Row)',
      (tester) async {
    final errors = await pumpDesktop(
      tester,
      WorkplaceDetailScreen(
        service: mockService(),
        permission: techLeader,
        workplaceId: 'wp2',
      ),
    );

    expect(tester.takeException(), isNull);
    expect(errors, isEmpty, reason: describe(errors));
    expect(
      find.textContaining('Полуавтоматическая линия'),
      findsWidgets,
    );
    expect(find.text('Рейтинг сотрудников'), findsOneWidget);
  });
}
