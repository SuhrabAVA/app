import 'package:flutter_test/flutter_test.dart';
import 'package:sheet_clone/modules/tasks/task_comment_presentation.dart';

void main() {
  // ВНИМАНИЕ. Функция нормализует «секунды → миллисекунды» по порогу
  // 2000000000000 (2e12). Текущий epoch в МИЛЛИСЕКУНДАХ (~1.79e12) этот порог
  // не превышает, поэтому значения в мс тоже домножаются на 1000. Правильный
  // порог — 2e9, как в _normTs (tasks_screen.dart). Порог здесь намеренно НЕ
  // трогается: это отдельный дефект вне периметра задачи, вынесен в отчёт.
  //
  // Поэтому тесты подают время в СЕКУНДАХ — так функция и работает сегодня
  // для реальных дат. Отдельный кейс ниже фиксирует ветку выше порога.
  int secondsOf(DateTime local) => local.millisecondsSinceEpoch ~/ 1000;

  group('formatTaskCommentTimestamp — год в дате', () {
    test('текущий год — без года', () {
      final now = DateTime(2026, 8, 3, 14, 5, 9);
      expect(
        formatTaskCommentTimestamp(secondsOf(now), reference: now),
        '03.08 14:05:09',
      );
    });

    test('прошлый год — с годом', () {
      final reference = DateTime(2026, 8, 3);
      final old = DateTime(2025, 11, 17, 9, 3, 4);
      expect(
        formatTaskCommentTimestamp(secondsOf(old), reference: reference),
        '17.11.2025 09:03:04',
      );
    });

    test('будущий год — тоже с годом', () {
      final reference = DateTime(2026, 8, 3);
      final future = DateTime(2027, 1, 2, 23, 59, 59);
      expect(
        formatTaskCommentTimestamp(secondsOf(future), reference: reference),
        '02.01.2027 23:59:59',
      );
    });

    test('31 декабря прошлого года — граница, год показывается', () {
      final reference = DateTime(2026, 1, 1, 0, 30);
      final lastYear = DateTime(2025, 12, 31, 23, 30, 0);
      expect(
        formatTaskCommentTimestamp(secondsOf(lastYear), reference: reference),
        '31.12.2025 23:30:00',
      );
    });

    test('1 января текущего года — года нет', () {
      final reference = DateTime(2026, 1, 1, 0, 30);
      final thisYear = DateTime(2026, 1, 1, 0, 0, 1);
      expect(
        formatTaskCommentTimestamp(secondsOf(thisYear), reference: reference),
        '01.01 00:00:01',
      );
    });

    test('без reference берётся текущий год — год не печатается', () {
      final now = DateTime.now();
      final formatted = formatTaskCommentTimestamp(secondsOf(now));
      expect(formatted, isNot(contains('${now.year}')));
      expect(formatted.split(' ').first.split('.').length, 2,
          reason: 'в дате текущего года только день и месяц');
    });

    test('пустые значения дают пустую строку', () {
      expect(formatTaskCommentTimestamp(null), '');
      expect(formatTaskCommentTimestamp(0), '');
      expect(formatTaskCommentTimestamp(-1), '');
    });
  });

  group('formatTaskCommentTimestamp — нормализация единиц (текущее поведение)',
      () {
    test('значение выше порога 2e12 трактуется как миллисекунды', () {
      // 2033-05-18 03:33:20 UTC — первое значение выше порога.
      const aboveThreshold = 2000000000000;
      final expected = DateTime.fromMillisecondsSinceEpoch(aboveThreshold);
      final reference = expected;
      String two(int n) => n.toString().padLeft(2, '0');
      expect(
        formatTaskCommentTimestamp(aboveThreshold, reference: reference),
        '${two(expected.day)}.${two(expected.month)} '
        '${two(expected.hour)}:${two(expected.minute)}:${two(expected.second)}',
      );
    });

    test(
        'РЕГРЕСС-МАРКЕР: значение в мс ниже порога уезжает в далёкое будущее '
        '(порог 2e12 вместо 2e9) — падёт, когда порог починят', () {
      final now = DateTime(2026, 8, 3, 14, 5, 9);
      final ms = now.millisecondsSinceEpoch;
      expect(ms < 2000000000000, isTrue,
          reason: 'текущий epoch в мс ниже неверного порога');
      final formatted = formatTaskCommentTimestamp(ms, reference: now);
      expect(formatted, contains('.58'),
          reason: 'сейчас мс домножаются на 1000 и дают ~58-тысячный год');
    });
  });
}
