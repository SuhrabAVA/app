/// Утилиты для работы с датами в аналитике.
class AnalyticsDateUtils {
  AnalyticsDateUtils._();

  /// Первый день месяца.
  static DateTime firstOfMonth(DateTime dt) =>
      DateTime(dt.year, dt.month, 1);

  /// Последний день месяца (включительно).
  static DateTime lastOfMonth(DateTime dt) {
    final next = DateTime(dt.year, dt.month + 1, 1);
    return next.subtract(const Duration(days: 1));
  }

  /// Количество дней в месяце.
  static int daysInMonth(DateTime dt) => lastOfMonth(dt).day;

  /// Проверяет, что дата находится внутри выбранного месяца.
  static bool isSameMonth(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month;

  /// Полночь даты, без времени.
  static DateTime atMidnight(DateTime dt) =>
      DateTime(dt.year, dt.month, dt.day);

  /// "Дата начала смены" для события: если событие началось до 6 утра,
  /// считаем его частью предыдущей даты (ночная смена).
  static DateTime shiftDateFor(DateTime moment) {
    if (moment.hour < 6) {
      return atMidnight(moment.subtract(const Duration(days: 1)));
    }
    return atMidnight(moment);
  }
}
