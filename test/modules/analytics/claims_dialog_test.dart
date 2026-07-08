import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sheet_clone/modules/analytics/services/analytics_permission_service.dart';
import 'package:sheet_clone/modules/analytics/widgets/claims_list_dialog.dart';
import 'package:sheet_clone/modules/analytics/widgets/employees_table.dart';

import 'analytics_test_fixtures.dart';

/// Фаза D «Претензии из чата»: кликабельное число в колонке «Претензии»
/// открывает диалог списка (и НЕ открывает деталку), ноль некликабелен,
/// диалог показывает претензии обоих источников (заказ и чат).
void main() {
  final techLeader = AnalyticsPermissionService(
    isTechLeader: true,
    currentEmployeeId: 'e1',
  );

  Future<void> pumpTable(
    WidgetTester tester, {
    ValueChanged<String>? onTap,
  }) async {
    // Широкий вьюпорт: колонка «Претензии» должна быть на экране (см.
    // комментарий в employees_inline_edit_test про ClipRect и hit-тесты).
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
              service: FakeAnalyticsService(mockState(claims: mockClaims)),
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

  testWidgets('клик по числу претензий открывает диалог и НЕ деталку',
      (tester) async {
    String? tapped;
    await pumpTable(tester, onTap: (id) => tapped = id);

    // e1 — 2 претензии (order + chat), число подчёркнуто и кликабельно.
    await tester.tap(find.byKey(const ValueKey('claims-e1')));
    await tester.pumpAndSettle();

    expect(find.byType(Dialog), findsOneWidget,
        reason: 'клик по числу должен открыть диалог списка претензий');
    expect(tapped, isNull,
        reason: 'тап по числу не должен всплывать до InkWell строки');
    expect(find.textContaining('Претензии за 06.2026'), findsOneWidget);
  });

  testWidgets('диалог показывает претензии обоих источников (заказ и чат)',
      (tester) async {
    await pumpTable(tester);
    await tester.tap(find.byKey(const ValueKey('claims-e1')));
    await tester.pumpAndSettle();

    // Заказная претензия: текст, автор, чип источника.
    expect(find.text('Брак приладки'), findsOneWidget);
    expect(find.text('Заказ'), findsOneWidget);
    expect(find.textContaining('Технический лидер'), findsOneWidget);
    // Чатовая: текст, автор, чип, дата.
    expect(find.text('Криво упакованная коробка'), findsOneWidget);
    expect(find.text('Чат'), findsOneWidget);
    expect(find.textContaining('Менеджер Мария'), findsOneWidget);
    expect(find.textContaining('03.06.2026'), findsOneWidget);
  });

  testWidgets('ноль претензий некликабелен: диалог не открывается',
      (tester) async {
    String? tapped;
    await pumpTable(tester, onTap: (id) => tapped = id);

    // e2 — без претензий: обычный текст, тап уходит в строку (деталка),
    // диалог не открывается.
    await tester.tap(find.byKey(const ValueKey('claims-e2')));
    await tester.pumpAndSettle();

    expect(find.byType(Dialog), findsNothing);
    expect(tapped, 'e2',
        reason: 'ноль — обычная ячейка, тап работает как клик по строке');
  });

  testWidgets('showClaimsListDialog рендерит пустое состояние',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showClaimsListDialog(
              context,
              employeeName: 'Иванов Иван',
              monthLabel: '06.2026',
              claims: const [],
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('Претензий за этот месяц нет'), findsOneWidget);
  });
}
