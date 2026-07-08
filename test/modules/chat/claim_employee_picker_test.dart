import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sheet_clone/modules/chat/chat_mention_candidate.dart';
import 'package:sheet_clone/modules/chat/widgets/claim_employee_picker.dart';

/// Фаза E «Претензии из чата»: smoke-тест диалога выбора сотрудников —
/// поиск фильтрует список, выбор возвращается и сохраняется при
/// переоткрытии (initiallySelected).
void main() {
  final candidates = <ChatMentionCandidate>[
    ChatMentionCandidate(
        id: 'e1',
        displayName: 'Иванов Иван',
        primarySearch: 'Иванов Иван',
        altSearch: 'Иван Иванов'),
    ChatMentionCandidate(
        id: 'e2',
        displayName: 'Петров Пётр',
        primarySearch: 'Петров Пётр',
        altSearch: 'Пётр Петров'),
    ChatMentionCandidate(
        id: 'e3',
        displayName: 'Сидорова Анна',
        primarySearch: 'Сидорова Анна',
        altSearch: 'Анна Сидорова'),
  ];

  Future<List<ChatMentionCandidate>> loader({String query = ''}) async =>
      candidates.where((c) => c.matches(query)).toList();

  /// Экран с кнопкой открытия пикера; результат складывается в [result].
  Widget host(
    List<ChatMentionCandidate> initiallySelected,
    void Function(List<ChatMentionCandidate>?) onResult,
  ) {
    return MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              final picked = await showClaimEmployeePicker(
                context,
                loadCandidates: loader,
                initiallySelected: initiallySelected,
              );
              onResult(picked);
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
  }

  testWidgets('поиск фильтрует список кандидатов', (tester) async {
    await tester.pumpWidget(host(const [], (_) {}));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // Без запроса видны все трое.
    expect(find.text('Иванов Иван'), findsOneWidget);
    expect(find.text('Петров Пётр'), findsOneWidget);
    expect(find.text('Сидорова Анна'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'сидорова');
    await tester.pumpAndSettle();

    expect(find.text('Сидорова Анна'), findsOneWidget);
    expect(find.text('Иванов Иван'), findsNothing);
    expect(find.text('Петров Пётр'), findsNothing);
  });

  testWidgets('выбор возвращается из диалога и переживает переоткрытие',
      (tester) async {
    List<ChatMentionCandidate>? result;
    await tester.pumpWidget(host(const [], (r) => result = r));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Иванов Иван'));
    await tester.tap(find.text('Сидорова Анна'));
    await tester.pump();
    await tester.tap(find.text('Готово'));
    await tester.pumpAndSettle();

    expect(result, isNotNull);
    expect(result!.map((c) => c.id), containsAll(['e1', 'e3']));

    // Переоткрытие с initiallySelected: чекбоксы выбранных отмечены.
    await tester.pumpWidget(host(result!, (_) {}));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final checked = tester
        .widgetList<CheckboxListTile>(find.byType(CheckboxListTile))
        .where((t) => t.value == true)
        .length;
    expect(checked, 2);
    expect(find.text('Выбрано: 2'), findsOneWidget);
  });

  testWidgets('отмена возвращает null (выбор не меняется)', (tester) async {
    List<ChatMentionCandidate>? result = const [];
    await tester.pumpWidget(host(const [], (r) => result = r));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Отмена'));
    await tester.pumpAndSettle();

    expect(result, isNull);
  });
}
