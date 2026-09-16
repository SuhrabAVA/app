import 'package:flutter_test/flutter_test.dart';
import 'package:sheet_clone/modules/orders/paper_usage_rules.dart';
import 'package:sheet_clone/modules/orders/production_ids.dart';
import 'package:sheet_clone/modules/tasks/task_model.dart';

PaperUsageRow _row({
  double plan = 3000,
  double written = 0,
  double available = 5000,
  bool inOrder = true,
}) =>
    PaperUsageRow(
      slotIndex: 0,
      paperId: 'paper-1',
      name: 'китс 7',
      format: '84',
      grammage: '45',
      unit: 'м',
      inOrder: inOrder,
      plan: plan,
      written: written,
      reserved: plan - written,
      stock: available,
      availableForOrder: available,
    );

void main() {
  group('остаток плана', () {
    test('первая смена — весь план', () {
      expect(_row().remaining, 3000);
    });

    test('вторая смена — план минус уже списанное', () {
      expect(_row(written: 1200).remaining, 1800);
    });

    test('списали больше плана — остаток ноль, а не минус', () {
      expect(_row(written: 3200).remaining, 0);
    });
  });

  group('проверка ввода', () {
    final row = _row(available: 1060);

    test('в пределах склада — можно', () {
      expect(validatePaperUsageInput('1060', row), isNull);
      expect(validatePaperUsageInput('500,5', row), isNull);
      expect(validatePaperUsageInput('0', row), isNull);
    });

    test('больше, чем есть на складе для заказа — нельзя', () {
      final error = validatePaperUsageInput('1061', row);
      expect(error, contains('1060'));
      expect(error, contains('пополнят'));
    });

    test('пусто, не число, минус', () {
      expect(validatePaperUsageInput('', row), isNotNull);
      expect(validatePaperUsageInput('abc', row), isNotNull);
      expect(validatePaperUsageInput('-5', row), isNotNull);
    });
  });

  group('этап бумаги', () {
    TaskModel task({required String stageId, String? group}) => TaskModel(
          id: 't',
          orderId: 'o',
          stageId: stageId,
          stageGroupKey: group,
        );

    test('совпадает по групповому ключу и по рабочему месту', () {
      expect(
        isPaperUsageStage(
          stageKey: wpBobbinUuid,
          task: task(stageId: wpBobbinUuid),
        ),
        isTrue,
      );
      expect(
        isPaperUsageStage(
          stageKey: 'group-1',
          task: task(stageId: wpBobbinUuid, group: 'group-1'),
        ),
        isTrue,
      );
    });

    test('другой этап и заказ без маршрута — не этап бумаги', () {
      expect(
        isPaperUsageStage(
          stageKey: wpBobbinUuid,
          task: task(stageId: wpFlexPrintingUuid),
        ),
        isFalse,
      );
      expect(
        isPaperUsageStage(stageKey: '', task: task(stageId: wpFlexPrintingUuid)),
        isFalse,
      );
    });
  });

  group('состояние с сервера', () {
    final state = PaperUsageState.fromJson({
      'stage_key': wpBobbinUuid,
      'closed': false,
      'has_fact_usage': true,
      'papers': [
        {
          'slot_index': 0,
          'paper_id': 'paper-1',
          'name': 'МЦБК',
          'format': '104',
          'grammage': '80',
          'plan': '8200.000',
          'written': 3000,
          'reserved': 5200,
          'stock': 17507.616,
          'available_for_order': 7307.616,
          'in_order': true,
        },
        {
          'slot_index': 1001,
          'paper_id': 'paper-old',
          'name': 'ВП',
          'plan': 0,
          'written': 500,
          'in_order': false,
        },
      ],
    });

    test('разбирает числа и строки', () {
      final paper = state.papers.first;
      expect(paper.plan, 8200);
      expect(paper.remaining, 5200);
      expect(paper.availableForOrder, closeTo(7307.616, 1e-9));
      expect(paper.title, 'МЦБК 104/80');
    });

    test('заменённая бумага не попадает в окно, но её списанное видно', () {
      expect(state.orderPapers.map((p) => p.paperId), ['paper-1']);
      expect(state.writtenByPaperId, {'paper-1': 3000, 'paper-old': 500});
      expect(state.totalWritten, 3500);
    });

    test('подпись в деталях — только пока этап идёт', () {
      expect(
        paperWrittenSuffix(state: state, paperId: 'paper-1'),
        'списано 3000 м',
      );
      final closed = PaperUsageState(
        stageKey: state.stageKey,
        closed: true,
        hasFactUsage: true,
        papers: state.papers,
      );
      expect(paperWrittenSuffix(state: closed, paperId: 'paper-1'), isNull);
      expect(paperWrittenSuffix(state: state, paperId: 'paper-x'), isNull);
    });
  });
}
