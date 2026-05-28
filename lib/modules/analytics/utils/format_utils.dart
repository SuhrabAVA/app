import 'package:intl/intl.dart';

class AnalyticsFormat {
  AnalyticsFormat._();

  static final NumberFormat _moneyFormat = NumberFormat.currency(
    locale: 'ru_RU',
    symbol: '₸',
    decimalDigits: 0,
  );

  static final NumberFormat _numberFormat = NumberFormat.decimalPattern('ru_RU');

  /// Деньги в формате "1 234 ₸".
  static String money(num? value) {
    final v = (value ?? 0).toDouble();
    if (!v.isFinite) return '0 ₸';
    return _moneyFormat.format(v.round());
  }

  /// Целые числа с разделителями.
  static String number(num? value) {
    final v = (value ?? 0).toDouble();
    if (!v.isFinite) return '0';
    return _numberFormat.format(v.round());
  }

  /// Дробное число с заданной точностью, корректно для скоростей.
  static String decimal(num? value, {int precision = 2}) {
    final v = (value ?? 0).toDouble();
    if (!v.isFinite) return '0';
    if (v == v.roundToDouble()) return v.toInt().toString();
    return v.toStringAsFixed(precision);
  }

  /// "X ч Y мин"
  static String hoursMinutes(int? minutes) {
    final m = (minutes ?? 0);
    final safe = m < 0 ? 0 : m;
    final h = safe ~/ 60;
    final mm = safe % 60;
    return '$h ч $mm мин';
  }

  /// Только минуты ("45 мин", "120 мин").
  static String onlyMinutes(int? minutes) {
    final m = (minutes ?? 0);
    final safe = m < 0 ? 0 : m;
    return '$safe мин';
  }

  /// "HH:MM" из минут с начала дня (поддержка переноса через полночь).
  static String minutesToHHMM(int minutes) {
    final m = minutes < 0 ? 0 : minutes;
    final normalized = m % (24 * 60);
    final h = (normalized ~/ 60).toString().padLeft(2, '0');
    final mm = (normalized % 60).toString().padLeft(2, '0');
    return '$h:$mm';
  }

  /// "DD.MM.YYYY"
  static String date(DateTime dt) =>
      DateFormat('dd.MM.yyyy').format(dt);

  /// "YYYY-MM" (месяц)
  static String month(DateTime dt) =>
      DateFormat('yyyy-MM').format(dt);

  /// "Май 2026"
  static String monthLong(DateTime dt) =>
      DateFormat.yMMMM('ru').format(dt);
}
