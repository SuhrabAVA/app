/// Нехватка материалов заказа — коротким списком.
///
/// ЗАЧЕМ
/// Текст нехватки собирается в одну строку и на карточке заказа обрезается на
/// первой позиции: «Не хватает 1000 г краски „285 Синий“:» — и всё. Когда не
/// хватает трёх бумаг и двух красок, сотрудник видит одну из пяти и идёт на
/// склад за неполным списком. Полный текст остаётся во всплывающей подсказке,
/// а на карточке нужен перечень: что именно и сколько.
///
/// ПОЧЕМУ РАЗБОР ТЕКСТА, А НЕ СТРУКТУРА В БАЗЕ
/// `orders.material_shortage_message` — строка, и её уже читают несколько
/// мест: карточка сверяет её с [isPaintNotSelectedShortage], список красок —
/// с [missingPaintNamesFromShortage]. Менять хранение ради показа значит
/// трогать все три; разбор добавляет четвёртого читателя, ничего не ломая.
/// Формат задаётся тут же, в `orders_provider`, и эти два места держатся
/// вместе — разъедутся, и список выродится в исходный текст, а не соврёт.
library;

import 'package:flutter/foundation.dart';

/// Одна позиция нехватки.
@immutable
class ShortageLine {
  const ShortageLine({
    required this.kind,
    required this.name,
    required this.amount,
  });

  /// «Б» — бумага, «К» — краска, пусто — строка, которую разобрать не вышло.
  final String kind;

  /// Название материала. У неразобранной строки — весь её текст.
  final String name;

  /// «3382.37 м», «35000 г», «нет карточки». Пусто у неразобранной строки.
  final String amount;

  bool get parsed => kind.isNotEmpty;

  /// «Б: Белый крафт — 3382.37 м»
  String get text => parsed ? '$kind: $name — $amount' : name;

  @override
  bool operator ==(Object other) =>
      other is ShortageLine &&
      other.kind == kind &&
      other.name == name &&
      other.amount == amount;

  @override
  int get hashCode => Object.hash(kind, name, amount);

  @override
  String toString() => text;
}

final RegExp _paperPattern =
    RegExp(r'Не хватает\s+([\d.,]+)\s*м\s+бумаги\s+«([^»]+)»');
final RegExp _paintPattern =
    RegExp(r'Не хватает\s+([\d.,]+)\s*г\s+краски\s+«([^»]+)»');
final RegExp _paintCardMissingPattern =
    RegExp(r'Краски\s+«([^»]+)»\s+нет на складе');

/// «Обязательный запас просел: нужно пополнить 5000 г» — хвост строки краски.
final RegExp _reserveNotePattern =
    RegExp(r'нужно пополнить\s+([\d.,]+)\s*г');

/// «(1000 г на заказ + 5000 г обязательного запаса)» — разбивка закупки у
/// краски, которой на складе нет вовсе.
final RegExp _purchaseBreakdownPattern = RegExp(
  r'([\d.,]+)\s*г\s+на заказ\s*\+\s*([\d.,]+)\s*г\s+обязательного запаса',
);

/// Разбирает текст нехватки в список позиций.
///
/// Порядок сохраняется — тот же, в котором позиции перечислены в сообщении:
/// сначала бумага, потом краски, как их собирает `_materialShortageMessage`.
///
/// ОБЯЗАТЕЛЬНЫЙ ЗАПАС ВХОДИТ В СТРОКУ КРАСКИ: «К: 285 Синий — 35000 г +
/// 5000 г». Снабженцу нужно привезти и то и другое одной закупкой, а раньше
/// вторая половина жила в хвосте сообщения и на карточке не показывалась
/// вовсе. У бумаги запаса нет, и строка остаётся короткой.
///
/// Текст, который не подошёл ни под один образец, не выбрасывается: он
/// становится строкой без вида. Молча потерять фразу вроде «Не выбрана
/// краска.» значило бы спрятать причину, по которой заказ стоит.
List<ShortageLine> parseShortageLines(String? message) {
  final text = (message ?? '').trim();
  if (text.isEmpty) return const <ShortageLine>[];

  // Сначала находим начала всех позиций, затем режем текст между ними: заметка
  // про обязательный запас приписана к СВОЕЙ краске и без нарезки досталась бы
  // соседней.
  final starts = <int, _Kind>{};
  for (final m in _paperPattern.allMatches(text)) {
    starts[m.start] = _Kind.paper;
  }
  for (final m in _paintPattern.allMatches(text)) {
    starts[m.start] = _Kind.paint;
  }
  for (final m in _paintCardMissingPattern.allMatches(text)) {
    starts[m.start] = _Kind.paintMissingCard;
  }

  if (starts.isEmpty) {
    return <ShortageLine>[ShortageLine(kind: '', name: text, amount: '')];
  }

  final positions = starts.keys.toList()..sort();
  final lines = <ShortageLine>[];

  final head = text.substring(0, positions.first).trim();
  if (head.isNotEmpty) {
    lines.add(ShortageLine(kind: '', name: head, amount: ''));
  }

  for (var i = 0; i < positions.length; i++) {
    final from = positions[i];
    final to = i + 1 < positions.length ? positions[i + 1] : text.length;
    final segment = text.substring(from, to);
    final line = _lineFromSegment(starts[from]!, segment);
    if (line != null) lines.add(line);
  }

  return lines;
}

enum _Kind { paper, paint, paintMissingCard }

ShortageLine? _lineFromSegment(_Kind kind, String segment) {
  switch (kind) {
    case _Kind.paper:
      final m = _paperPattern.firstMatch(segment);
      if (m == null) return null;
      return ShortageLine(
        kind: 'Б',
        name: (m.group(2) ?? '').trim(),
        amount: '${(m.group(1) ?? '').trim()} м',
      );

    case _Kind.paint:
      final m = _paintPattern.firstMatch(segment);
      if (m == null) return null;
      final shortage = '${(m.group(1) ?? '').trim()} г';
      final reserve = _reserveNotePattern.firstMatch(segment);
      return ShortageLine(
        kind: 'К',
        name: (m.group(2) ?? '').trim(),
        amount: reserve == null
            ? shortage
            : '$shortage + ${(reserve.group(1) ?? '').trim()} г',
      );

    case _Kind.paintMissingCard:
      final m = _paintCardMissingPattern.firstMatch(segment);
      if (m == null) return null;
      // Краски нет вовсе: закупка разложена на «на заказ» и «обязательный
      // запас». Показываем обе половины — это и есть то, что везти.
      final breakdown = _purchaseBreakdownPattern.firstMatch(segment);
      return ShortageLine(
        kind: 'К',
        name: (m.group(1) ?? '').trim(),
        amount: breakdown == null
            ? 'нет карточки на складе'
            : '${(breakdown.group(1) ?? '').trim()} г '
                '+ ${(breakdown.group(2) ?? '').trim()} г',
      );
  }
}
