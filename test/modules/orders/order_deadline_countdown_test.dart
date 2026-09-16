import 'package:flutter_test/flutter_test.dart';
import 'package:sheet_clone/modules/orders/order_deadline_countdown.dart';
import 'package:sheet_clone/modules/orders/order_model.dart';
import 'package:sheet_clone/modules/orders/product_model.dart';
import 'package:sheet_clone/utils/kostanay_time.dart';

OrderModel order({
  required DateTime orderDate,
  DateTime? dueDate,
  OrderStatus status = OrderStatus.in_production,
  DateTime? completedAt,
  DateTime? shippedAt,
}) {
  final model = OrderModel(
    id: 'o1',
    manager: 'м',
    customer: 'ТОО Ромашка',
    orderDate: orderDate,
    dueDate: dueDate,
    product: ProductModel(
      id: 'p1',
      type: 'Листы',
      quantity: 1000,
      width: 10,
      height: 10,
      depth: 10,
    ),
    status: status.name,
  );
  model.completedAt = completedAt;
  model.shippedAt = shippedAt;
  return model;
}

void main() {
  // Костанай — UTC+5. Полдень 5 сентября по Костанаю — это 07:00 UTC.
  DateTime kostanay(int day, [int hour = 0, int minute = 0]) =>
      DateTime.utc(2026, 9, day, hour, minute).subtract(kKostanayUtcOffset);

  group('deadlineFromDueDate', () {
    test('срок истекает в конце указанного дня, а не в его полночь', () {
      // Иначе заказ со сроком «10 сентября» считался бы просроченным весь
      // десятый день — тот самый, на который его и планировали.
      final deadline = deadlineFromDueDate(DateTime.utc(2026, 9, 10, 3));
      expect(deadline, kostanay(10, 23, 59).add(const Duration(seconds: 59)));
    });

    test('день берётся по Костанаю, а не по UTC', () {
      // 9 сентября 20:00 UTC — это уже 10 сентября 01:00 в Костанае.
      final deadline = deadlineFromDueDate(DateTime.utc(2026, 9, 9, 20));
      final local = toKostanayTime(deadline);
      expect(local.day, 10);
      expect(local.hour, 23);
    });
  });

  group('orderCountdown', () {
    test('без срока считать нечего', () {
      expect(
        orderCountdown(
          createdAt: kostanay(1),
          dueDate: null,
          now: kostanay(2),
        ),
        isNull,
      );
    });

    test('остаток — до конца дня срока', () {
      final countdown = orderCountdown(
        createdAt: kostanay(1),
        dueDate: DateTime.utc(2026, 9, 3),
        now: kostanay(2, 12),
      )!;
      // От полудня 2-го до 23:59:59 3-го — сутки с половиной без секунды.
      expect(countdown.remaining.inHours, 35);
      expect(countdown.overdue, isFalse);
    });

    test('в момент создания запас полный, на сроке — нулевой', () {
      final created = kostanay(1);
      final due = DateTime.utc(2026, 9, 11);
      final atStart = orderCountdown(
        createdAt: created,
        dueDate: due,
        now: created,
      )!;
      final atEnd = orderCountdown(
        createdAt: created,
        dueDate: due,
        now: deadlineFromDueDate(due),
      )!;
      expect(atStart.fractionLeft, closeTo(1, 0.001));
      expect(atEnd.fractionLeft, closeTo(0, 0.001));
    });

    test('середина срока — половина запаса', () {
      final created = kostanay(1, 23, 59);
      final due = DateTime.utc(2026, 9, 11);
      final deadline = deadlineFromDueDate(due);
      final middle = created.add(
        Duration(
          milliseconds: deadline.difference(created).inMilliseconds ~/ 2,
        ),
      );
      final countdown = orderCountdown(
        createdAt: created,
        dueDate: due,
        now: middle,
      )!;
      expect(countdown.fractionLeft, closeTo(0.5, 0.01));
    });

    test('просрочка уходит в минус, но запас ниже нуля не опускается', () {
      final countdown = orderCountdown(
        createdAt: kostanay(1),
        dueDate: DateTime.utc(2026, 9, 3),
        now: kostanay(6, 12),
      )!;
      expect(countdown.overdue, isTrue);
      expect(countdown.remaining.isNegative, isTrue);
      expect(countdown.fractionLeft, 0);
    });

    test('срок раньше создания не делится на ноль', () {
      final countdown = orderCountdown(
        createdAt: kostanay(10),
        dueDate: DateTime.utc(2026, 9, 1),
        now: kostanay(10, 1),
      )!;
      expect(countdown.fractionLeft, 0);
    });

    test('остановленные часы стоят на моменте завершения', () {
      final finished = kostanay(2, 12);
      final countdown = orderCountdown(
        createdAt: kostanay(1),
        dueDate: DateTime.utc(2026, 9, 3),
        now: kostanay(9, 12),
        finishedAt: finished,
      )!;
      expect(countdown.running, isFalse);
      // Проверка на укус: если бы часы шли, заказ был бы давно просрочен.
      expect(countdown.overdue, isFalse);
      expect(countdown.remaining.inHours, 35);
    });
  });

  group('countdownForOrder', () {
    test('завершённый заказ останавливает часы на своей отметке', () {
      final countdown = countdownForOrder(
        order(
          orderDate: kostanay(1),
          dueDate: DateTime.utc(2026, 9, 3),
          status: OrderStatus.completed,
          completedAt: kostanay(2, 12),
        ),
        now: kostanay(20),
      )!;
      expect(countdown.running, isFalse);
      expect(countdown.overdue, isFalse);
    });

    test('у завершённого без отметки показывать нечего', () {
      // Подставить «сейчас» значило бы придумать заказу опоздание.
      expect(
        countdownForOrder(
          order(
            orderDate: kostanay(1),
            dueDate: DateTime.utc(2026, 9, 3),
            status: OrderStatus.completed,
          ),
          now: kostanay(20),
        ),
        isNull,
      );
    });

    test('незавершённый заказ считает до сих пор', () {
      final countdown = countdownForOrder(
        order(
          orderDate: kostanay(1),
          dueDate: DateTime.utc(2026, 9, 3),
          completedAt: kostanay(2),
        ),
        now: kostanay(20),
      )!;
      expect(countdown.running, isTrue);
      expect(countdown.overdue, isTrue);
    });
  });

  group('formatCountdown', () {
    test('дни, часы, минуты и секунды', () {
      expect(
        formatCountdown(
          const Duration(days: 12, hours: 4, minutes: 28, seconds: 7),
        ),
        '12д 04:28:07',
      );
    });

    test('меньше суток — без дней', () {
      expect(
        formatCountdown(const Duration(hours: 4, minutes: 28, seconds: 7)),
        '04:28:07',
      );
    });

    test('нули не теряются', () {
      expect(formatCountdown(Duration.zero), '00:00:00');
      expect(formatCountdown(const Duration(seconds: 5)), '00:00:05');
    });

    test('просрочка помечается минусом', () {
      expect(
        formatCountdown(const Duration(days: -2, hours: -1)),
        '−2д 01:00:00',
      );
    });
  });

  group('countdownColor', () {
    test('полный запас зелёный, исчерпанный красный', () {
      expect(countdownColor(1), kCountdownGreen);
      expect(countdownColor(0), kCountdownRed);
    });

    test('середина — жёлтая', () {
      expect(countdownColor(0.5), kCountdownAmber);
    });

    test('за границами шкалы цвет не срывается', () {
      expect(countdownColor(5), kCountdownGreen);
      expect(countdownColor(-3), kCountdownRed);
    });

    test('красное ползёт к зелёному без скачков', () {
      // Проверка на укус: три ступени вместо перелива дали бы одинаковый цвет
      // на соседних долях, и «осталось чуть-чуть» не отличалось бы от «полно».
      final samples = <double>[0, 0.25, 0.5, 0.75, 1];
      final colors = samples.map(countdownColor).toList(growable: false);
      expect(colors.toSet().length, samples.length);
      // «Краснота» — отношение красного канала к зелёному: у чистого красного
      // оно велико, у зелёного близко к нулю. Через жёлтую середину, где обоих
      // каналов много, оно падает без разрывов.
      final redness = colors
          .map((c) => (c.r * 255 + 1) / (c.g * 255 + 1))
          .toList(growable: false);
      for (var i = 1; i < redness.length; i++) {
        expect(redness[i], lessThan(redness[i - 1]));
      }
    });
  });
}
