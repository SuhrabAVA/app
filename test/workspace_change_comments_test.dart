import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sheet_clone/modules/tasks/task_comment_presentation.dart';
import 'package:sheet_clone/modules/tasks/workspace_change_comments.dart';

void main() {
  group('buildPaperChangeComment', () {
    test('сохраняет все поля материала и до, и после правки', () {
      final payload = buildPaperChangeComment(
        before: const [
          PaperChangeRow(
            name: 'Тестовая бумага',
            format: '333',
            grammage: '444',
            widthB: 333,
            lengthMeters: 50,
          )
        ],
        after: const [
          PaperChangeRow(
            name: 'Тестовая бумага',
            format: '333',
            grammage: '444',
            widthB: 333,
            lengthMeters: 100,
          )
        ],
        reason: 'Нужно',
      );

      final comment = decodeChangeComment(payload)!;
      expect(comment.kind, 'paper');
      expect(comment.reason, 'Нужно');
      expect(comment.rows, hasLength(1));

      final row = comment.rows.single;
      expect(row.op, ChangeRowOp.changed);
      expect(row.name, 'Тестовая бумага');
      // Все пять полей остаются в пейлоаде — ничего не выброшено.
      expect(
        row.before.map((f) => f.display).toList(),
        ['Ф 333', 'Гр 444', 'Ш 333', 'К —', 'L 50.00 м'],
      );
      expect(
        row.after.map((f) => f.display).toList(),
        ['Ф 333', 'Гр 444', 'Ш 333', 'К —', 'L 100.00 м'],
      );
      // Подсветить надо только длину.
      expect(row.changedLabels, {'L'});
      expect(row.changedAfterFields.single.display, 'L 100.00 м');
      expect(row.delta, '+50.00 м');
    });

    test('добавленная бумага несёт полную спецификацию', () {
      final comment = decodeChangeComment(buildPaperChangeComment(
        before: const [PaperChangeRow(name: 'Бумага', lengthMeters: 10)],
        after: const [
          PaperChangeRow(name: 'Бумага', lengthMeters: 10),
          PaperChangeRow(
            name: 'Тест Подпергамент Небеленный',
            format: '84',
            grammage: '52',
            widthB: 22,
            lengthMeters: 50,
          ),
        ],
        reason: 'Нужно',
      ))!;

      final added = comment.rows.last;
      expect(added.op, ChangeRowOp.added);
      expect(added.slot, 2);
      expect(added.name, 'Тест Подпергамент Небеленный');
      expect(
        added.after.map((f) => f.display).toList(),
        ['Ф 84', 'Гр 52', 'Ш 22', 'К —', 'L 50.00 м'],
      );
    });

    test('смена материала отмечается переименованием', () {
      final comment = decodeChangeComment(buildPaperChangeComment(
        before: const [
          PaperChangeRow(name: 'Тестовая', format: '333', lengthMeters: 50)
        ],
        after: const [
          PaperChangeRow(name: 'Крафт', format: '100', lengthMeters: 30)
        ],
        reason: 'замена',
      ))!;

      final row = comment.rows.single;
      expect(row.renamed, isTrue);
      expect(row.beforeName, 'Тестовая');
      expect(row.afterName, 'Крафт');
      expect(row.changedLabels, {'Ф', 'L'});
      expect(row.delta, '−20.00 м');
    });

    test('удалённая бумага сохраняется отдельной строкой', () {
      final comment = decodeChangeComment(buildPaperChangeComment(
        before: const [
          PaperChangeRow(name: 'Бумага', lengthMeters: 10),
          PaperChangeRow(name: 'Лишняя', lengthMeters: 5),
        ],
        after: const [PaperChangeRow(name: 'Бумага', lengthMeters: 10)],
        reason: '',
      ))!;

      expect(comment.rows.last.op, ChangeRowOp.removed);
      expect(comment.rows.last.name, 'Лишняя');
      expect(comment.reason, isEmpty);
    });
  });

  group('buildPaintChangeComment', () {
    test('количество и комментарий краски идут одним значением', () {
      final comment = decodeChangeComment(buildPaintChangeComment(
        before: const [
          PaintChangeRow(name: 'Тест Чёрный Чёрный', grams: 20, info: '34234')
        ],
        after: const [
          PaintChangeRow(name: 'Тест Чёрный Чёрный', grams: 2000, info: '34234')
        ],
        reason: 'цосицори',
      ))!;

      final row = comment.rows.single;
      expect(comment.rowLabel, 'Краска');
      expect(row.before.single.display, '20 г • 34234');
      expect(row.after.single.display, '2000 г • 34234');
      expect(row.changedAfterFields, hasLength(1));
    });

    test('добавленная краска несёт количество и инфо', () {
      final comment = decodeChangeComment(buildPaintChangeComment(
        before: const [],
        after: const [
          PaintChangeRow(name: 'тест Синий', grams: 180, info: 'ву')
        ],
        reason: 'нужен второй цвет',
      ))!;

      expect(comment.rows.single.op, ChangeRowOp.added);
      expect(comment.rows.single.after.single.display, '180 г • ву');
    });
  });

  group('текстовое представление', () {
    test('разворачивает пейлоад со всеми полями', () {
      final payload = buildPaperChangeComment(
        before: const [
          PaperChangeRow(
            name: 'Тестовая бумага',
            format: '333',
            grammage: '444',
            widthB: 333,
            lengthMeters: 50,
          )
        ],
        after: const [
          PaperChangeRow(
            name: 'Тестовая бумага',
            format: '333',
            grammage: '444',
            widthB: 333,
            lengthMeters: 100,
          )
        ],
        reason: 'Нужно',
      );

      final text = describeTaskComment('paper_change', payload);
      expect(text, 'Изменение бумаги из рабочего пространства.\n'
          'Бумага №1 Тестовая бумага: Ф 333, Гр 444, Ш 333, К —, L 50.00 м '
          '→ L 100.00 м (Δ +50.00 м)\n'
          'Причина: Нужно');
    });

    test('комментарий старого формата показывается как есть', () {
      const legacy = 'Изменение бумаги из рабочего пространства.\n'
          'Бумага №1 Было: … Стало: …\nПричина: Нужно';
      expect(describeTaskComment('paper_change', legacy), legacy);
      expect(decodeChangeComment(legacy), isNull);
    });

    test('чужой JSON не принимается за наш пейлоад', () {
      expect(decodeChangeComment('{"type":"time_event"}'), isNull);
    });
  });

  group('TaskChangeCommentBody', () {
    testWidgets('рисует все поля, старое и новое значение', (tester) async {
      final comment = decodeChangeComment(buildPaperChangeComment(
        before: const [
          PaperChangeRow(
            name: 'Тестовая бумага',
            format: '333',
            grammage: '444',
            widthB: 333,
            lengthMeters: 50,
          )
        ],
        after: const [
          PaperChangeRow(
            name: 'Тестовая бумага',
            format: '333',
            grammage: '444',
            widthB: 333,
            lengthMeters: 100,
          )
        ],
        reason: 'Нужно',
      ))!;

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 800,
            child: TaskChangeCommentBody(comment: comment),
          ),
        ),
      ));

      expect(tester.takeException(), isNull);
      expect(
        find.text('ИЗМЕНЕНИЕ БУМАГИ ИЗ РАБОЧЕГО ПРОСТРАНСТВА'),
        findsOneWidget,
      );

      final rendered = tester
          .widgetList<RichText>(find.byType(RichText))
          .map((widget) => widget.text.toPlainText())
          .join(' ');
      // Все поля на месте, включая неизменные.
      for (final token in ['Бумага №1', 'Тестовая бумага', 'Ф 333', 'Гр 444',
        'Ш 333', 'К —', 'L 50.00 м', 'L 100.00 м', 'Δ +50.00 м', 'Причина:']) {
        expect(rendered, contains(token), reason: 'нет «$token»');
      }
    });

    testWidgets('добавленная строка помечается пилюлей', (tester) async {
      final comment = decodeChangeComment(buildPaintChangeComment(
        before: const [],
        after: const [
          PaintChangeRow(name: 'тест Синий', grams: 180, info: 'ву')
        ],
        reason: 'нужен второй цвет',
      ))!;

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 800,
            child: TaskChangeCommentBody(comment: comment),
          ),
        ),
      ));

      expect(tester.takeException(), isNull);
      expect(find.text('+ Добавлена'), findsOneWidget);
    });
  });
}
