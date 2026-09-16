import 'package:flutter_test/flutter_test.dart';
import 'package:sheet_clone/modules/tasks/quantity_status_service.dart';
import 'package:sheet_clone/modules/tasks/stage_quantity_records.dart';

/// Инвариант: фактическое количество по заказу — это тираж этапа, а НЕ сумма
/// персональных долей участников.
///
/// Совместный этап с помощниками раньше давал в `orders.actual_qty` тираж,
/// умноженный на число участников: RPC `complete_task_stage` пишет каждому
/// помощнику `quantity_share` с полным Q, а владельцу — `quantity_team_total`
/// с тем же Q, и сумма по задаче складывала всё подряд. От этого числа
/// считаются отгрузка и списания со склада.

Map<String, dynamic> _comment({
  required String type,
  required String userId,
  String text = '',
  int timestamp = 0,
}) =>
    <String, dynamic>{
      'id': '$type-$userId-$timestamp',
      'type': type,
      'text': text,
      'userId': userId,
      'timestamp': timestamp,
    };

/// Сумма количеств задачи по тем же правилам, что применяет
/// `TaskProvider._quantityForActualQty`.
double _orderQuantity({
  required List<String> assignees,
  required List<Map<String, dynamic>> comments,
}) {
  final helperIds = helperIdsFromComments(
    assignees: assignees,
    comments: comments,
  );
  var total = 0.0;
  for (final comment in comments) {
    if (!countsTowardOrderQuantity(comment: comment, helperIds: helperIds)) {
      continue;
    }
    total += double.parse((comment['text'] ?? '0').toString());
  }
  return total;
}

void main() {
  const owner = 'owner-1';
  const helperA = 'helper-a';
  const helperB = 'helper-b';

  group('факт по заказу не складывает персональные доли', () {
    test('совместный этап с двумя помощниками даёт Q, а не 3×Q', () {
      final comments = [
        _comment(type: 'joined', userId: helperA, timestamp: 1),
        _comment(type: 'joined', userId: helperB, timestamp: 2),
        // Так пишет RPC complete_task_stage: полное Q каждому помощнику…
        _comment(
            type: 'quantity_share',
            userId: helperA,
            text: '30000',
            timestamp: 10),
        _comment(
            type: 'quantity_share',
            userId: helperB,
            text: '30000',
            timestamp: 11),
        // …и полное Q владельцу.
        _comment(
            type: 'quantity_team_total',
            userId: owner,
            text: '30000',
            timestamp: 12),
      ];

      expect(
        _orderQuantity(
          assignees: const [owner, helperA, helperB],
          comments: comments,
        ),
        30000,
      );

      // Контроль: без правила ролей те же данные дают 90000. Без этой
      // проверки тест прошёл бы и на пустом наборе записей, ничего не доказав.
      var withoutRoles = 0.0;
      for (final comment in comments) {
        if (!countsTowardOrderQuantity(
            comment: comment, helperIds: const {})) {
          continue;
        }
        withoutRoles += double.parse((comment['text'] ?? '0').toString());
      }
      expect(withoutRoles, 90000);
    });

    test('доля удалённого помощника не идёт в факт', () {
      // Помощника убрали с этапа: из assignees он исчез, но joined остался —
      // по нему роль и определяется.
      final comments = [
        _comment(type: 'joined', userId: helperA, timestamp: 1),
        _comment(
            type: 'quantity_share',
            userId: helperA,
            text: '4000',
            timestamp: 5),
        _comment(
            type: 'quantity_team_total',
            userId: owner,
            text: '12000',
            timestamp: 20),
      ];

      expect(
        _orderQuantity(assignees: const [owner], comments: comments),
        12000,
      );
    });
  });

  group('тираж этапа считается полностью', () {
    test('фиксации владельца на пересменах складываются с финальной', () {
      final comments = [
        _comment(type: 'joined', userId: helperA, timestamp: 1),
        // Пересмена: количество фиксирует инициатор — владелец.
        _comment(
            type: 'quantity_share',
            userId: owner,
            text: '7000',
            timestamp: 5),
        _comment(
            type: 'quantity_team_total',
            userId: owner,
            text: '5000',
            timestamp: 20),
      ];

      expect(
        _orderQuantity(
          assignees: const [owner, helperA],
          comments: comments,
        ),
        12000,
      );
    });

    test('отдельные исполнители: каждый quantity_done идёт в сумму', () {
      // В режиме «отдельный исполнитель» помощников нет — joined никто не
      // пишет, и каждый вводит своё количество сам.
      final comments = [
        _comment(
            type: 'quantity_done', userId: owner, text: '600', timestamp: 5),
        _comment(
            type: 'quantity_done', userId: 'worker-2', text: '400',
            timestamp: 6),
      ];

      expect(
        _orderQuantity(
          assignees: const [owner, 'worker-2'],
          comments: comments,
        ),
        1000,
      );
    });

    test('легаси-задача без assignees считается как раньше', () {
      // Владельца не определить — правило ролей не применяется, поведение
      // остаётся прежним.
      final comments = [
        _comment(type: 'joined', userId: helperA, timestamp: 1),
        _comment(
            type: 'quantity_share',
            userId: helperA,
            text: '900',
            timestamp: 5),
        _comment(
            type: 'quantity_done', userId: owner, text: '100', timestamp: 6),
      ];

      expect(
        _orderQuantity(assignees: const [], comments: comments),
        1000,
      );
    });
  });

  group('новый учёт: тираж отдельно, доли отдельно', () {
    test('доли, рассчитанные сервером, в факт не идут — даже у владельца', () {
      // Так выглядит задача после recompute_task_quantity_shares: один тираж
      // сегмента и доли участников, помеченные generated.
      final comments = [
        _comment(type: 'joined', userId: helperA, timestamp: 1),
        _comment(
            type: 'quantity_stage_total',
            userId: owner,
            text: '{"actual":30000,"unit":"шт"}',
            timestamp: 20),
        _comment(
            type: 'quantity_share',
            userId: owner,
            text: '{"actual":20000,"generated":true}',
            timestamp: 21),
        _comment(
            type: 'quantity_share',
            userId: helperA,
            text: '{"actual":10000,"generated":true}',
            timestamp: 22),
      ];

      final helperIds = helperIdsFromComments(
        assignees: const [owner, helperA],
        comments: comments,
      );
      var total = 0.0;
      for (final comment in comments) {
        if (!countsTowardOrderQuantity(
            comment: comment, helperIds: helperIds)) {
          continue;
        }
        total += (tryDecodeQuantityPayload(comment['text'].toString())?['actual']
                as num?)
            ?.toDouble() ??
            0;
      }
      expect(total, 30000);
    });

    test('доля владельца без флага generated в факт идёт (ручная запись)', () {
      // Правка техлида и ручной ввод флага не несут — их считать надо.
      expect(
        countsTowardOrderQuantity(
          comment: _comment(
              type: 'quantity_share',
              userId: owner,
              text: '{"actual":5000}'),
          helperIds: const {},
        ),
        isTrue,
      );
    });

    test('тираж сегмента — распознаваемый тип', () {
      expect(kOrderQuantityCommentTypes, contains(kStageTotalCommentType));
    });
  });

  group('определение ролей', () {
    test('помощник — автор joined, не совпадающий с первым в assignees', () {
      final helpers = helperIdsFromComments(
        assignees: const [owner, helperA],
        comments: [
          _comment(type: 'joined', userId: helperA),
          _comment(type: 'joined', userId: owner),
        ],
      );
      expect(helpers, {helperA});
    });

    test('userId читается и в snake_case', () {
      final helpers = helperIdsFromComments(
        assignees: const [owner],
        comments: [
          <String, dynamic>{'type': 'joined', 'user_id': helperB},
        ],
      );
      expect(helpers, {helperB});
    });

    test('assignees разбирается из сырого значения колонки', () {
      expect(assigneesFromRaw([owner, ' ', helperA]), [owner, helperA]);
      expect(assigneesFromRaw(null), isEmpty);
      expect(stageOwnerId(assigneesFromRaw([owner, helperA])), owner);
    });

    test('нерелевантные типы комментариев в сумму не идут', () {
      expect(
        countsTowardOrderQuantity(
          comment: _comment(
              type: 'helper_removed_qty', userId: owner, text: '5000'),
          helperIds: const {},
        ),
        isFalse,
      );
      expect(
        countsTowardOrderQuantity(
          comment: _comment(type: 'setup_done', userId: owner, text: '1'),
          helperIds: const {},
        ),
        isFalse,
      );
    });
  });
}
