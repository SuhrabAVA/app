import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sheet_clone/modules/orders/paper_usage_rules.dart';
import 'package:sheet_clone/modules/tasks/paper_usage_dialog.dart';

PaperUsageRow _row({
  required int slot,
  required String id,
  required String name,
  double plan = 3000,
  double written = 0,
  double available = 10000,
}) =>
    PaperUsageRow(
      slotIndex: slot,
      paperId: id,
      name: name,
      format: '84',
      grammage: '45',
      unit: 'м',
      inOrder: true,
      plan: plan,
      written: written,
      reserved: plan - written,
      stock: available,
      availableForOrder: available,
    );

PaperUsageState _state(List<PaperUsageRow> rows) => PaperUsageState(
      stageKey: 'stage',
      closed: false,
      hasFactUsage: rows.any((r) => r.written > 0),
      papers: rows,
    );

Future<PaperUsageDialogResult?> _open(
  WidgetTester tester,
  PaperUsageState state,
) async {
  PaperUsageDialogResult? result;
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            result = await showPaperUsageDialog(
              context,
              state: state,
              actionLabel: 'за вашу смену',
            );
          },
          child: const Text('открыть'),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('открыть'));
  await tester.pumpAndSettle();
  return result;
}

void main() {
  testWidgets('подставлен остаток плана, итог — сумма по бумагам',
      (tester) async {
    final state = _state([
      _row(slot: 0, id: 'p1', name: 'китс 7', plan: 3000, written: 1200),
      _row(slot: 1, id: 'p2', name: 'ВП', plan: 800),
    ]);
    await _open(tester, state);

    expect(find.text('1800'), findsOneWidget); // 3000 − 1200
    expect(find.text('800'), findsOneWidget);
    expect(find.text('Будет зачтено на этапе: 2600 м'), findsOneWidget);
    expect(find.textContaining('уже списано: 1200 м'), findsOneWidget);
  });

  testWidgets('нулевой расход сохранить нельзя', (tester) async {
    final state = _state([_row(slot: 0, id: 'p1', name: 'китс 7')]);
    await _open(tester, state);

    await tester.enterText(find.byType(TextField).first, '0');
    await tester.pump();

    expect(
      find.text('Укажите расход хотя бы по одной бумаге.'),
      findsOneWidget,
    );
    final save = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(save.onPressed, isNull);
  });

  testWidgets('сохранение отдаёт расход по каждой бумаге', (tester) async {
    final state = _state([
      _row(slot: 0, id: 'p1', name: 'китс 7', plan: 3000),
      _row(slot: 1, id: 'p2', name: 'ВП', plan: 800),
    ]);
    PaperUsageDialogResult? result;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await showPaperUsageDialog(
                context,
                state: state,
                actionLabel: 'за вашу смену',
              );
            },
            child: const Text('открыть'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('открыть'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).at(0), '2500');
    await tester.enterText(find.byType(TextField).at(1), '750,5');
    await tester.pump();
    await tester.tap(find.text('Сохранить'));
    await tester.pumpAndSettle();

    expect(result?.openPaperEditor, isFalse);
    expect(result?.qtyByPaperId, {'p1': 2500.0, 'p2': 750.5});
  });

  testWidgets('больше, чем на складе для заказа, сохранить нельзя',
      (tester) async {
    final state = _state([
      _row(slot: 0, id: 'p1', name: 'китс 7', plan: 3000, available: 1060),
    ]);
    await _open(tester, state);

    await tester.enterText(find.byType(TextField).first, '2000');
    await tester.pump();

    expect(find.textContaining('только 1060 м'), findsOneWidget);
    final save = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(save.onPressed, isNull);
  });
}
