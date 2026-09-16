import 'package:flutter_test/flutter_test.dart';
import 'package:sheet_clone/modules/tasks/task_comment_presentation.dart';
import 'package:sheet_clone/modules/tasks/task_model.dart';

void main() {
  // Единицы в tasks.comments смешанные: старые метки в секундах, новые в
  // миллисекундах. Порог нормализации — kEpochSecondsThreshold (2e9), и оба
  // варианта должны давать одну и ту же дату.
  //
  // formatTaskCommentTimestamp показывает Костанайское время (UTC+5). Метки в
  // БД — UTC epoch, поэтому тест задаёт ЖЕЛАЕМОЕ костанайское время показа и
  // переводит его в исходный UTC-epoch (−5 ч). Так ожидания в expect остаются
  // прежними и не зависят от таймзоны машины CI.
  int _epochMsFor(DateTime kostanayWall) => DateTime.utc(
        kostanayWall.year,
        kostanayWall.month,
        kostanayWall.day,
        kostanayWall.hour,
        kostanayWall.minute,
        kostanayWall.second,
      ).subtract(const Duration(hours: 5)).millisecondsSinceEpoch;
  int secondsOf(DateTime kostanayWall) => _epochMsFor(kostanayWall) ~/ 1000;
  int millisOf(DateTime kostanayWall) => _epochMsFor(kostanayWall);

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

  group('formatTaskCommentTimestamp — нормализация единиц', () {
    test('секунды и миллисекунды дают одну и ту же дату', () {
      final moment = DateTime(2026, 8, 3, 14, 5, 9);
      expect(
        formatTaskCommentTimestamp(millisOf(moment), reference: moment),
        formatTaskCommentTimestamp(secondsOf(moment), reference: moment),
      );
      expect(
        formatTaskCommentTimestamp(millisOf(moment), reference: moment),
        '03.08 14:05:09',
      );
    });

    test('РЕГРЕСС: метка в мс больше не уезжает в 58-тысячный год', () {
      final moment = DateTime(2026, 8, 3, 14, 5, 9);
      final ms = millisOf(moment);
      // Именно это значение попадало под старый порог 2e12 и домножалось.
      expect(ms < 2000000000000, isTrue);
      final formatted = formatTaskCommentTimestamp(ms, reference: moment);
      expect(formatted, isNot(contains('58')));
      expect(formatted, '03.08 14:05:09');
    });
  });

  group('normalizeEpochToMillis', () {
    test('секунды домножаются', () {
      expect(normalizeEpochToMillis(1785744309), 1785744309000);
    });

    test('миллисекунды не трогаются', () {
      expect(normalizeEpochToMillis(1785744309000), 1785744309000);
    });

    test('граница 2e9: ниже — секунды, ровно и выше — миллисекунды', () {
      expect(kEpochSecondsThreshold, 2000000000);
      expect(normalizeEpochToMillis(kEpochSecondsThreshold - 1),
          (kEpochSecondsThreshold - 1) * 1000);
      expect(normalizeEpochToMillis(kEpochSecondsThreshold),
          kEpochSecondsThreshold);
      expect(normalizeEpochToMillis(kEpochSecondsThreshold + 1),
          kEpochSecondsThreshold + 1);
    });

    test('микросекунды делятся на 1000', () {
      expect(normalizeEpochToMillis(1785744309000000), 1785744309000);
      expect(normalizeEpochToMillis(kEpochMicrosecondsThreshold),
          kEpochMicrosecondsThreshold,
          reason: 'ровно на границе — уже миллисекунды');
    });

    test('ноль и отрицательные возвращаются как есть', () {
      expect(normalizeEpochToMillis(0), 0);
      expect(normalizeEpochToMillis(-1), -1);
      expect(normalizeEpochToMillis(-1785744309), -1785744309);
    });

    test('значение из будущего в мс не трогается', () {
      final future = DateTime(2030, 1, 1).millisecondsSinceEpoch;
      expect(normalizeEpochToMillis(future), future);
    });

    test('значение из будущего в секундах домножается', () {
      final future = DateTime(2030, 1, 1).millisecondsSinceEpoch ~/ 1000;
      expect(future < kEpochSecondsThreshold, isTrue,
          reason: '2030 год в секундах ещё ниже границы 2033-го');
      expect(normalizeEpochToMillis(future), future * 1000);
    });
  });

  group('formatTaskCommentTimestamp — граничные значения', () {
    test('ноль и отрицательные дают пустую строку', () {
      expect(formatTaskCommentTimestamp(0), '');
      expect(formatTaskCommentTimestamp(-1), '');
      expect(formatTaskCommentTimestamp(-1785744309000), '');
    });

    test('дата из будущего печатается с годом', () {
      final reference = DateTime(2026, 8, 3);
      final future = DateTime(2030, 3, 17, 8, 9, 10);
      expect(
        formatTaskCommentTimestamp(millisOf(future), reference: reference),
        '17.03.2030 08:09:10',
      );
      expect(
        formatTaskCommentTimestamp(secondsOf(future), reference: reference),
        '17.03.2030 08:09:10',
      );
    });
  });
}
