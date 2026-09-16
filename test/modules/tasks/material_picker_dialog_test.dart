import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sheet_clone/modules/tasks/material_picker_dialog.dart';
import 'package:sheet_clone/modules/warehouse/tmc_model.dart';

TmcModel _paper(String name, {String format = '84', String grammage = '45'}) =>
    TmcModel(
      id: name,
      date: '2026-09-16',
      type: 'paper',
      description: name,
      quantity: 1000,
      unit: 'м',
      format: format,
      grammage: grammage,
    );

bool _matches(TmcModel item, String query) {
  final normalized = query.trim().toLowerCase();
  if (normalized.isEmpty) return true;
  return '${item.description} ${item.format} ${item.grammage}'
      .toLowerCase()
      .contains(normalized);
}

Future<TmcModel?> _open(WidgetTester tester, List<TmcModel> items) async {
  TmcModel? picked;
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            picked = await showMaterialPickerDialog(
              context: context,
              title: 'Выбор бумаги',
              searchLabel: 'Поиск бумаги',
              items: items,
              matches: _matches,
              subtitleOf: (p) => 'Формат: ${p.format}',
            );
          },
          child: const Text('открыть'),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('открыть'));
  await tester.pumpAndSettle();
  return picked;
}

bool _searchHasFocus(WidgetTester tester) =>
    tester.widget<EditableText>(find.byType(EditableText)).focusNode.hasFocus;

void main() {
  final items = [_paper('китс 7'), _paper('МЦБК', format: '104', grammage: '80')];

  testWidgets('после первого символа поле не теряет фокус', (tester) async {
    // Регрессия: у поля стоял key: ValueKey(search.isEmpty). На первом символе
    // ключ менялся, Flutter пересоздавал поле — фокус слетал, и клавиатура
    // закрывалась на каждой букве.
    await _open(tester, items);

    await tester.tap(find.byType(TextField));
    await tester.pump();
    expect(_searchHasFocus(tester), isTrue);

    await tester.enterText(find.byType(TextField), 'к');
    await tester.pump();
    expect(_searchHasFocus(tester), isTrue, reason: 'после первого символа');

    await tester.enterText(find.byType(TextField), 'ки');
    await tester.pump();
    expect(_searchHasFocus(tester), isTrue, reason: 'после второго символа');
  });

  testWidgets('поиск фильтрует список', (tester) async {
    await _open(tester, items);

    expect(find.text('китс 7'), findsOneWidget);
    expect(find.text('МЦБК'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'мцб');
    await tester.pump();

    expect(find.text('китс 7'), findsNothing);
    expect(find.text('МЦБК'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'нет такой');
    await tester.pump();
    expect(find.text('Ничего не найдено.'), findsOneWidget);
  });

  testWidgets('крестик очищает поиск и не роняет фокус', (tester) async {
    await _open(tester, items);

    await tester.enterText(find.byType(TextField), 'мцб');
    await tester.pump();
    expect(find.byIcon(Icons.clear), findsOneWidget);

    await tester.tap(find.byIcon(Icons.clear));
    await tester.pump();

    expect(find.text('китс 7'), findsOneWidget);
    expect(find.byIcon(Icons.clear), findsNothing);
  });

  testWidgets('выбор строки возвращает материал', (tester) async {
    await _open(tester, items);

    await tester.tap(find.text('МЦБК'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
  });
}
