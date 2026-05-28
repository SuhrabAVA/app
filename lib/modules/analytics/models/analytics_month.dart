import '../utils/date_utils.dart';
import '../utils/format_utils.dart';

/// Месяц аналитики. Без времени, всегда указывает на первое число.
class AnalyticsMonth {
  final DateTime _first;

  AnalyticsMonth(DateTime any)
      : _first = AnalyticsDateUtils.firstOfMonth(any);

  AnalyticsMonth.fromYearMonth(int year, int month)
      : _first = DateTime(year, month, 1);

  factory AnalyticsMonth.current() => AnalyticsMonth(DateTime.now());

  int get year => _first.year;
  int get month => _first.month;
  DateTime get firstDay => _first;
  DateTime get lastDay => AnalyticsDateUtils.lastOfMonth(_first);
  int get daysCount => AnalyticsDateUtils.daysInMonth(_first);

  /// Диапазон месяца [start, endExclusive).
  DateTime get nextMonthFirstDay => DateTime(_first.year, _first.month + 1, 1);

  /// Предыдущий месяц.
  AnalyticsMonth get previous => AnalyticsMonth.fromYearMonth(
        _first.month == 1 ? _first.year - 1 : _first.year,
        _first.month == 1 ? 12 : _first.month - 1,
      );

  /// Все N предыдущих месяцев в обратном порядке (свежие первыми).
  List<AnalyticsMonth> previousMonths(int n) {
    final result = <AnalyticsMonth>[];
    var m = previous;
    for (var i = 0; i < n; i++) {
      result.add(m);
      m = m.previous;
    }
    return result;
  }

  /// "YYYY-MM"
  String get isoKey => AnalyticsFormat.month(_first);

  /// "YYYY-MM-DD" первого дня.
  String get firstDayIso =>
      '${_first.year}-${_first.month.toString().padLeft(2, '0')}-01';

  String get humanTitle => AnalyticsFormat.monthLong(_first);

  bool contains(DateTime moment) =>
      moment.year == _first.year && moment.month == _first.month;

  @override
  bool operator ==(Object other) =>
      other is AnalyticsMonth &&
      other._first.year == _first.year &&
      other._first.month == _first.month;

  @override
  int get hashCode => _first.year * 100 + _first.month;
}
