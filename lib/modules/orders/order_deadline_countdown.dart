/// Обратный отсчёт до срока выполнения заказа.
///
/// Часы идут от СОЗДАНИЯ заказа до конца дня, указанного в «дате выполнения».
/// Именно до конца дня, а не до его полуночи: срок «10 сентября» означает, что
/// весь десятый день ещё в запасе, а отсчёт от полуночи объявлял бы заказ
/// просроченным ровно в тот день, на который его и планировали.
///
/// Считается всё в абсолютных мгновениях (UTC), и только ГРАНИЦА ДНЯ берётся
/// по Костанаю: база хранит UTC, устройства в цеху живут по Костанаю, и
/// смешение двух шкал давало бы ошибку в пять часов — на суточном сроке это
/// пятая часть остатка. Единая шкала внутри убирает и второй риск: не нужно
/// помнить, какой из трёх отметок уже приведён к местному времени, а какой
/// ещё нет.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../../utils/kostanay_time.dart';
import 'order_model.dart';

/// Состояние обратного отсчёта на конкретный момент.
@immutable
class OrderCountdown {
  const OrderCountdown({
    required this.remaining,
    required this.fractionLeft,
    required this.running,
  });

  /// Сколько осталось. Отрицательное — срок прошёл.
  final Duration remaining;

  /// Доля НЕИЗРАСХОДОВАННОГО срока: 1 — заказ только создан, 0 — время вышло.
  ///
  /// Считается от полной длины срока (создание → дедлайн), а не от абсолютных
  /// часов: у заказа на сутки и у заказа на месяц «мало времени» наступает в
  /// разные моменты, и один и тот же цвет для обоих врал бы половине заказов.
  final double fractionLeft;

  /// Идут ли часы. У завершённого заказа они стоят на моменте завершения.
  final bool running;

  bool get overdue => remaining.isNegative;
}

/// Дедлайн заказа — миг окончания указанного дня по Костанаю, в UTC.
DateTime deadlineFromDueDate(DateTime dueDate) {
  final local = toKostanayTime(dueDate);
  final endOfLocalDay =
      DateTime.utc(local.year, local.month, local.day, 23, 59, 59);
  return endOfLocalDay.subtract(kKostanayUtcOffset);
}

/// Обратный отсчёт по трём отметкам. Все они — абсолютные мгновения; часовой
/// пояс участвует только в границе дня внутри [deadlineFromDueDate].
///
/// [finishedAt] — момент, на котором часы остановлены (заказ завершён).
/// Возвращает `null`, когда считать нечего: срок не задан.
/// [exactDeadline] — брать [dueDate] как точный миг, а не как конец дня.
/// Нужен назначенному вручную сроку: «завтра к 14:00» означает именно 14:00,
/// и достройка до 23:59 подарила бы цеху десять часов, которых он не обещал.
OrderCountdown? orderCountdown({
  required DateTime createdAt,
  required DateTime? dueDate,
  required DateTime now,
  DateTime? finishedAt,
  bool exactDeadline = false,
}) {
  if (dueDate == null) return null;
  final deadline =
      exactDeadline ? dueDate.toUtc() : deadlineFromDueDate(dueDate);
  final start = createdAt.toUtc();
  final at = (finishedAt ?? now).toUtc();

  final remaining = deadline.difference(at);
  final total = deadline.difference(start);

  // Срок в прошлом относительно создания (задним числом или тот же день,
  // уже прошедший) — делить не на что, и запас считаем исчерпанным.
  final double fractionLeft;
  if (total.inMilliseconds <= 0) {
    fractionLeft = 0;
  } else {
    final raw = remaining.inMilliseconds / total.inMilliseconds;
    fractionLeft = raw.clamp(0.0, 1.0);
  }

  return OrderCountdown(
    remaining: remaining,
    fractionLeft: fractionLeft,
    running: finishedAt == null,
  );
}

/// Обратный отсчёт для заказа. `null` — показывать нечего.
///
/// У завершённого заказа часы останавливаются на отметке завершения: красный
/// счётчик просрочки, растущий на давно сданном заказе, — шум, а не сведения.
/// Если отметки нет (старые записи), показывать нечего вовсе: подставить
/// «сейчас» значило бы придумать заказу опоздание, которого не было.
/// Срок, по которому живёт показ: обещание производства, если оно есть.
///
/// `promised_at` назначает цех в МУПЗ, `due_date` — менеджер при оформлении.
/// Первый перекрывает второй ВЕЗДЕ, где показывается срок, но не заменяет его
/// в данных: договорённость с заказчиком остаётся на месте, иначе исчез бы сам
/// факт сдвига.
DateTime? effectiveDeadlineDate(OrderModel order) =>
    order.promisedAt ?? order.dueDate;

/// Срок назначен вручную. По этому признаку показ переворачивается: обычный
/// срок — цветные цифры на белом, назначенный — белые в цветной плашке.
bool hasManualDeadline(OrderModel order) => order.promisedAt != null;

/// У назначенного срока указан час, а не только день.
///
/// Полночь считаем «днём без времени»: сотрудник, выбравший только дату,
/// обещает день целиком, и отсчёт до 00:00 отнял бы у него сутки.
bool hasExactPromisedTime(OrderModel order) {
  final promised = order.promisedAt;
  if (promised == null) return false;
  final local = toKostanayTime(promised);
  return local.hour != 0 || local.minute != 0;
}

/// Дата срока для показа.
///
/// Время печатается только у назначенного вручную срока и только когда оно не
/// полночь: у `due_date` времени нет вовсе — там граница дня, — и «17.09 00:00»
/// читалось бы как «к полуночи», хотя весь день ещё в запасе.
String formatDeadlineDate(DateTime value, {required bool manual}) {
  final local = toKostanayTime(value);
  String two(int v) => v.toString().padLeft(2, '0');
  final date = '${two(local.day)}.${two(local.month)}.${local.year}';
  if (!manual) return date;
  if (local.hour == 0 && local.minute == 0) return date;
  return '$date ${two(local.hour)}:${two(local.minute)}';
}

OrderCountdown? countdownForOrder(OrderModel order, {required DateTime now}) {
  final finished = order.statusEnum == OrderStatus.completed
      ? (order.completedAt ?? order.shippedAt)
      : null;
  if (order.statusEnum == OrderStatus.completed && finished == null) {
    return null;
  }
  return orderCountdown(
    createdAt: order.orderDate,
    dueDate: effectiveDeadlineDate(order),
    now: now,
    finishedAt: finished,
    exactDeadline: hasExactPromisedTime(order),
  );
}

/// Остаток в виде «12д 04:28:07»; до суток — без дней, просрочка — с минусом.
String formatCountdown(Duration remaining) {
  final overdue = remaining.isNegative;
  final abs = remaining.abs();
  final days = abs.inDays;
  final hours = abs.inHours % 24;
  final minutes = abs.inMinutes % 60;
  final seconds = abs.inSeconds % 60;
  String two(int value) => value.toString().padLeft(2, '0');
  final clock = '${two(hours)}:${two(minutes)}:${two(seconds)}';
  final body = days > 0 ? '${days}д $clock' : clock;
  return overdue ? '−$body' : body;
}

/// Палитра отсчёта: запас есть — зелёный, половина срока — жёлтый, конец —
/// красный. Промежуточные положения смешиваются, поэтому цвет ползёт плавно,
/// а не прыгает тремя ступенями.
const Color kCountdownGreen = Color(0xFF16A34A);
const Color kCountdownAmber = Color(0xFFF59E0B);
const Color kCountdownRed = Color(0xFFDC2626);

/// Цвет отсчёта по доле оставшегося срока.
Color countdownColor(double fractionLeft) {
  final t = fractionLeft.clamp(0.0, 1.0);
  if (t >= 0.5) {
    return Color.lerp(kCountdownAmber, kCountdownGreen, (t - 0.5) * 2)!;
  }
  return Color.lerp(kCountdownRed, kCountdownAmber, t * 2)!;
}

/// Текст для истории заказа: как сдвинули срок.
///
/// Снятие обещания называет, к чему заказ вернулся, — иначе запись «срок:
/// 20.09.2026 → не назначен» не отвечает на главный вопрос «а когда теперь».
String describePromisedDateChange({
  required DateTime? before,
  required DateTime? after,
  required DateTime? dueDate,
}) {
  String show(DateTime? value, {required bool manual}) => value == null
      ? 'не назначен'
      : formatDeadlineDate(value, manual: manual);

  if (after == null) {
    final fallback = dueDate == null
        ? 'срок заказчика не указан'
        : 'срок заказчика ${formatDeadlineDate(dueDate, manual: false)}';
    return 'Срок завершения снят: ${show(before, manual: true)} → $fallback';
  }
  return 'Срок завершения: ${show(before, manual: true)} '
      '→ ${show(after, manual: true)}';
}
