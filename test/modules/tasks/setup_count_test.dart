import 'package:flutter_test/flutter_test.dart';
import 'package:sheet_clone/modules/personnel/workplace_model.dart';
import 'package:sheet_clone/modules/tasks/setup_count.dart';

void main() {
  group('computeSetupCount — режим «По размеру» (bySize)', () {
    const dims = SetupDims(width: 100, height: 200, depth: 50);

    test('первый заказ на рабочем месте (нет предыдущего) — приладка засчитывается', () {
      final r = computeSetupCount(
        mode: PriladkaCalcMode.bySize,
        currentDims: dims,
        previousDims: null,
        hasPrevious: false,
      );
      expect(r.qty, 1);
      expect(r.dataWarning, isFalse);
    });

    test('размеры совпадают с предыдущим заказом — приладка НЕ засчитывается', () {
      final r = computeSetupCount(
        mode: PriladkaCalcMode.bySize,
        currentDims: dims,
        previousDims: const SetupDims(width: 100, height: 200, depth: 50),
        hasPrevious: true,
      );
      expect(r.qty, 0);
      expect(r.dataWarning, isFalse);
    });

    test('отличается один параметр (глубина) — приладка засчитывается', () {
      final r = computeSetupCount(
        mode: PriladkaCalcMode.bySize,
        currentDims: dims,
        previousDims: const SetupDims(width: 100, height: 200, depth: 51),
        hasPrevious: true,
      );
      expect(r.qty, 1);
    });

    test('отличаются все параметры — приладка засчитывается', () {
      final r = computeSetupCount(
        mode: PriladkaCalcMode.bySize,
        currentDims: dims,
        previousDims: const SetupDims(width: 1, height: 2, depth: 3),
        hasPrevious: true,
      );
      expect(r.qty, 1);
    });

    test('у текущего заказа нет размера (0/null) — несовпадение + предупреждение', () {
      for (final current in const [
        SetupDims(width: 0, height: 200, depth: 50), // 0 = не задан
        SetupDims(width: 100, height: null, depth: 50),
        SetupDims(), // все отсутствуют
      ]) {
        final r = computeSetupCount(
          mode: PriladkaCalcMode.bySize,
          currentDims: current,
          previousDims: dims,
          hasPrevious: true,
        );
        expect(r.qty, 1, reason: 'неполные размеры → приладка засчитывается');
        expect(r.dataWarning, isTrue,
            reason: 'неполные данные должны фиксироваться для проверки');
      }
    });

    test('у предыдущего заказа нет размеров — несовпадение + предупреждение', () {
      final r = computeSetupCount(
        mode: PriladkaCalcMode.bySize,
        currentDims: dims,
        previousDims: const SetupDims(width: 100, height: 200),
        hasPrevious: true,
      );
      expect(r.qty, 1);
      expect(r.dataWarning, isTrue);
    });
  });

  group('computeSetupCount — остальные режимы', () {
    test('byColors: приладок столько, сколько красок', () {
      final r = computeSetupCount(
        mode: PriladkaCalcMode.byColors,
        paintsCount: 3,
      );
      expect(r.qty, 3);
      expect(r.dataWarning, isFalse);
    });

    test('byColors: красок нет — 0 приладок + предупреждение', () {
      final r = computeSetupCount(
        mode: PriladkaCalcMode.byColors,
        paintsCount: 0,
      );
      expect(r.qty, 0);
      expect(r.dataWarning, isTrue);
    });

    test('byOrder: ровно одна приладка независимо от параметров', () {
      final r = computeSetupCount(
        mode: PriladkaCalcMode.byOrder,
        paintsCount: 7,
        currentDims: const SetupDims(width: 1, height: 2, depth: 3),
      );
      expect(r.qty, 1);
    });

    test('режим не выбран (null) — легаси 1 приладка + предупреждение', () {
      final r = computeSetupCount(mode: null);
      expect(r.qty, 1);
      expect(r.dataWarning, isTrue);
    });
  });

  group('setupDoneCommentText', () {
    test('целое количество пишется без дробной части', () {
      expect(setupDoneCommentText(3),
          'Завершил(а) настройку станка (приладок: 3)');
    });

    test('ноль сохраняется в маркере (важно для аналитики)', () {
      final text = setupDoneCommentText(0, note: 'размеры совпадают');
      expect(text, contains('приладок: 0'));
      expect(text, contains('размеры совпадают'));
    });
  });

  group('parsePriladkaCalcMode', () {
    test('парсит значения БД и null', () {
      expect(parsePriladkaCalcMode('by_colors'), PriladkaCalcMode.byColors);
      expect(parsePriladkaCalcMode('by_order'), PriladkaCalcMode.byOrder);
      expect(parsePriladkaCalcMode('by_size'), PriladkaCalcMode.bySize);
      expect(parsePriladkaCalcMode(null), isNull);
      expect(parsePriladkaCalcMode('unknown'), isNull);
    });

    test('round-trip через dbValue', () {
      for (final mode in PriladkaCalcMode.values) {
        expect(parsePriladkaCalcMode(mode.dbValue), mode);
      }
    });
  });
}
