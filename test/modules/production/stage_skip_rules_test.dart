import 'package:flutter_test/flutter_test.dart';
import 'package:sheet_clone/modules/orders/production_ids.dart';
import 'package:sheet_clone/modules/production/stage_skip_rules.dart';

void main() {
  group('причина пропуска', () {
    test('пустая и символическая причина не принимается', () {
      expect(isValidSkipReason(null), isFalse);
      expect(isValidSkipReason(''), isFalse);
      expect(isValidSkipReason('  - '), isFalse);
      expect(isValidSkipReason('ок'), isFalse);
    });

    test('осмысленная причина принимается', () {
      expect(isValidSkipReason('этап не нужен'), isTrue);
    });
  });

  group('отметка в ленте', () {
    test('содержит причину и имя пропустившего', () {
      // Регрессия: отметка писалась от `system` без причины — кто и зачем
      // пропустил этап, узнать было нельзя.
      final note = skipStageNote(
        reason: '  заказу не нужна высечка ',
        actorName: 'Иванова Анна',
      );
      expect(note, 'Этап пропущен: заказу не нужна высечка (Иванова Анна)');
    });

    test('без имени — только причина', () {
      expect(skipStageNote(reason: 'дубль этапа', actorName: '  '),
          'Этап пропущен: дубль этапа');
    });
  });

  group('автор для журнала склада', () {
    test('имя пропустившего вместо system', () {
      expect(skipStageActor('Иванова Анна'), 'Иванова Анна');
    });

    test('без имени остаётся system, запись не без автора', () {
      expect(skipStageActor(null), 'system');
      expect(skipStageActor(''), 'system');
    });
  });

  group('предупреждения', () {
    test('пропуск флексопечати предупреждает о несписанной краске', () {
      // 23 заказа с пропущенной флексопечатью остались без списания краски.
      final warnings = skipStageWarnings(<String>[' $wpFlexPrintingUuid ']);
      expect(warnings.any((w) => w.contains('Краска заказа НЕ спишется')),
          isTrue);
    });

    test('другой этап о краске не предупреждает', () {
      final warnings = skipStageWarnings(<String>[wpBobbinUuid]);
      expect(warnings.any((w) => w.contains('Краска')), isFalse);
      expect(warnings, isNotEmpty);
    });
  });
}
