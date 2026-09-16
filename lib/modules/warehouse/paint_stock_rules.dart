/// Неприкасаемый запас краски на складе.
///
/// На каждой краске склад обязан всегда держать [kUntouchablePaintGrams].
/// Этот запас — не резерв под заказ: он не принадлежит никому и существует,
/// чтобы производство не вставало на нуле. Поэтому он вычитается ОДИН РАЗ из
/// складского остатка, а не по 5 кг с каждого заказа: сколько бы заказов
/// краску ни просило, неприкасаемым остаётся один и тот же пятикилограммовый
/// хвост.
///
/// Запас закрыт для БРОНИ ПОД ЗАКАЗ — и только для неё: заказ не может ни
/// забронировать эти граммы, ни считаться обеспеченным за их счёт, ни увести
/// их в производство через свой резерв.
///
/// Запас НЕ закрыт для:
///   * фактического расхода в производстве — краска, которую печатник уже
///     израсходовал, свершившийся факт, и запрет списания разошёлся бы с
///     реальностью;
///   * РУЧНОГО СПИСАНИЯ И ПЕРЕМЕЩЕНИЯ СО СКЛАДА — кладовщик распоряжается
///     физической банкой: её отдают в другой цех, проливают, списывают по
///     негодности. Запрет здесь не сохранял краску, а лишь расходился с тем,
///     что уже произошло на полке, и заставлял «дорисовывать» остаток
///     инвентаризацией.
///
/// Поэтому остаток может опуститься ниже 5 кг — см. [needsReplenishment].
library;

/// Обязательный неснижаемый остаток каждой краски, граммы.
const double kUntouchablePaintGrams = 5000;

/// Свободный остаток краски: то, что можно забронировать под заказ.
///
/// Из складского остатка вычитаются непогашенные брони ЧУЖИХ заказов и
/// неприкасаемый запас. Никогда не отрицателен: «минус триста граммов
/// свободно» — это те же ноль свободных, а знак минус только путал бы
/// сообщения о нехватке.
double availablePaintGrams({
  required double stockGrams,
  double reservedByOthersGrams = 0,
}) {
  final free = stockGrams - reservedByOthersGrams - kUntouchablePaintGrams;
  return free > 0 ? free : 0;
}

/// Сколько краски нужно ДОКУПИТЬ, чтобы заказ был обеспечен.
///
/// Считается так, как это звучит для снабженца: потребность заказа плюс
/// неприкасаемые 5 кг минус то, что на складе реально свободно под этот заказ.
/// Для краски, которой на складе нет вовсе (`stockGrams` = 0), получается
/// ровно «потребность + 5000 г».
double paintGramsToPurchase({
  required double neededGrams,
  required double stockGrams,
  double reservedByOthersGrams = 0,
}) {
  final missing = neededGrams +
      kUntouchablePaintGrams +
      reservedByOthersGrams -
      stockGrams;
  return missing > 0 ? missing : 0;
}

/// Хватает ли краски заказу с учётом неприкасаемого запаса.
bool hasEnoughPaint({
  required double neededGrams,
  required double stockGrams,
  double reservedByOthersGrams = 0,
  double epsilon = 1e-6,
}) =>
    availablePaintGrams(
          stockGrams: stockGrams,
          reservedByOthersGrams: reservedByOthersGrams,
        ) +
        epsilon >=
        neededGrams;

/// Просел ли неприкасаемый запас — то есть должен ли сотрудник его пополнить.
///
/// Запущенные заказы при этом не трогаем: краску они уже расходуют, и отбирать
/// её задним числом нельзя. Пополнения требует следующий заказ, которому эта
/// краска понадобится, — там нехватка и всплывёт.
bool needsReplenishment(double stockGrams) =>
    stockGrams < kUntouchablePaintGrams;

/// Сколько граммов не хватает до неприкасаемого запаса.
double replenishmentGrams(double stockGrams) {
  final gap = kUntouchablePaintGrams - stockGrams;
  return gap > 0 ? gap : 0;
}

/// Сколько граммов свободно СВЕРХ неприкасаемого запаса.
///
/// Потолком ручного списания это число больше НЕ является: со склада запас
/// отдают (см. заголовок файла). Осталось справочной величиной — её показывают
/// кладовщику в диалоге списания, чтобы он видел, с какого числа начинает
/// расходовать неснижаемый остаток.
double freeAbovePaintReserveGrams(double stockGrams) {
  final free = stockGrams - kUntouchablePaintGrams;
  return free > 0 ? free : 0;
}

/// Граммы в текст сообщения: без хвоста «.00» у целых значений.
String formatPaintGrams(double grams) {
  final rounded = (grams * 100).round() / 100;
  var text = rounded.toStringAsFixed(2);
  if (text.contains('.')) {
    text = text.replaceFirst(RegExp(r'0+$'), '');
    text = text.replaceFirst(RegExp(r'\.$'), '');
  }
  return '$text г';
}

/// Ключ сопоставления краски заказа со складской карточкой.
///
/// Заказ хранит краску ИМЕНЕМ, склад — полем `description`, и связывает их
/// только текст. Поэтому ключ нормализуется одинаково с обеих сторон: регистр
/// и лишние пробелы к разным краскам не относятся, а «192D  Красный» с двойным
/// пробелом — это та же краска, что «192D Красный».
///
/// Дальше нормализация не идёт СОЗНАТЕЛЬНО: «192D Красный» и «192D Синий» —
/// разные краски, и любое сопоставление «по похожести» рано или поздно выдаст
/// заказу не тот пигмент.
String normalizePaintKey(String value) =>
    value.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

/// Описание складской карточки краски.
///
/// Обычный ввод склеивается по складской привычке — «название + цвет». Но
/// когда карточку заводят ПО ЗАПРОСУ ЗАКАЗА (кнопка «Завести краску» на
/// фиолетовой карточке), описание обязано совпасть с именем краски в заказе
/// дословно: связывает их только текст, и любая добавка ломает связь.
///
/// Так и ломалась: цвет в форме обязателен, поэтому запрос «невидимая краска»
/// сохранялся как «невидимая краска Красный». Заказ такой карточки не находил
/// и оставался в «Ожидании материалов» навсегда — сколько краски ни заводи.
String paintCardDescription({
  required String name,
  required String color,
  String? requestedName,
}) {
  final requested = (requestedName ?? '').trim();
  if (requested.isNotEmpty) return requested;
  final trimmedName = name.trim();
  final trimmedColor = color.trim();
  if (trimmedColor.isEmpty) return trimmedName;
  if (trimmedName.isEmpty) return trimmedColor;
  return '$trimmedName $trimmedColor';
}

/// Единственный источник фразы «краски нет на складе».
///
/// Текст пишут два места — расчёт статуса в `OrdersProvider` и форма заказа, —
/// а читает третье: карточка заказа, которой по этой фразе нужно понять, что
/// краску надо ЗАВЕСТИ, а не докупить, и подсветить себя фиолетовым. Поэтому
/// формулировка живёт здесь: разъедься она хоть на слово, карточка перестала
/// бы узнавать случай и молча красилась бы как обычная нехватка.
String missingPaintShortageMessage({
  required String paintName,
  required double neededGrams,
}) {
  final purchase =
      paintGramsToPurchase(neededGrams: neededGrams, stockGrams: 0);
  return 'Краски «$paintName» нет на складе. '
      'Нужно заказать ${formatPaintGrams(purchase)} '
      '(${formatPaintGrams(neededGrams)} на заказ + '
      '${formatPaintGrams(kUntouchablePaintGrams)} обязательного запаса).';
}

final RegExp _missingPaintPattern =
    RegExp(r'Краски\s+«([^»]+)»\s+нет на складе');

/// Названия красок, которых нет на складе, из текста нехватки заказа.
///
/// Пустой список означает обычную нехватку — краска на складе есть, просто её
/// мало. Эти два случая ведут себя по-разному: первый чинится заведением
/// карточки на складе, второй — закупкой.
List<String> missingPaintNamesFromShortage(String? message) {
  final text = (message ?? '').trim();
  if (text.isEmpty) return const <String>[];
  final names = <String>[];
  for (final match in _missingPaintPattern.allMatches(text)) {
    final name = (match.group(1) ?? '').trim();
    if (name.isNotEmpty && !names.contains(name)) names.add(name);
  }
  return names;
}
