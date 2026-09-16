import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sheet_clone/modules/personnel/personnel_list_controls.dart';
import 'package:sheet_clone/modules/personnel/personnel_list_filters.dart';

Widget host(Widget child) =>
    MaterialApp(home: Scaffold(body: Center(child: child)));

void main() {
  testWidgets('чип «да/нет» открывает варианты и отдаёт выбор', (tester) async {
    var value = TriFilter.any;
    await tester.pumpWidget(host(StatefulBuilder(
      builder: (context, setState) => TriFilterChip(
        label: 'Станок',
        value: value,
        yes: 'да',
        no: 'нет',
        onChanged: (v) => setState(() => value = v),
      ),
    )));

    // Нажатие ловит меню вокруг чипа (сам чип не перехватывает жест).
    await tester.tap(find.byType(ChoiceFilterChip<TriFilter>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('нет').last);
    await tester.pumpAndSettle();

    expect(value, TriFilter.no);
    expect(find.text('Станок: нет'), findsOneWidget);
  });

  testWidgets('мультивыбор: галочки, «Готово» и подпись чипа', (tester) async {
    var selected = <String>{};
    await tester.pumpWidget(host(StatefulBuilder(
      builder: (context, setState) => MultiSelectFilterChip(
        label: 'Должность',
        options: const [
          FilterOption('op', 'Оператор'),
          FilterOption('pack', 'Упаковщик'),
        ],
        selected: selected,
        onChanged: (ids) => setState(() => selected = ids),
      ),
    )));

    await tester.tap(find.text('Должность'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Оператор'));
    await tester.tap(find.text('Упаковщик'));
    await tester.tap(find.text('Готово'));
    await tester.pumpAndSettle();

    expect(selected, {'op', 'pack'});
    expect(find.text('Должность: Оператор +1'), findsOneWidget);
  });

  testWidgets('поле поиска: крестик очищает запрос, «Сбросить» виден при фильтре',
      (tester) async {
    final controller = TextEditingController();
    var query = '';
    var resets = 0;
    await tester.pumpWidget(host(StatefulBuilder(
      builder: (context, setState) => PersonnelFilterBar(
        controller: controller,
        hint: 'Поиск',
        onQueryChanged: (v) => setState(() => query = v),
        shown: query.isEmpty ? 5 : 1,
        total: 5,
        isActive: query.isNotEmpty,
        onReset: () => resets++,
      ),
    )));

    expect(find.text('Сбросить'), findsNothing);
    await tester.enterText(find.byType(TextField), 'равиль');
    await tester.pump();
    expect(query, 'равиль');
    expect(find.text('Найдено 1 из 5'), findsOneWidget);

    await tester.tap(find.text('Сбросить'));
    expect(resets, 1);

    await tester.tap(find.byIcon(Icons.close));
    await tester.pump();
    expect(query, '');
    expect(controller.text, '');
  });
}
