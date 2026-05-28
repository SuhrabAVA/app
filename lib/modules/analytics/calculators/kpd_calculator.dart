import '../models/analytics_event.dart';
import '../models/analytics_month.dart';
import 'analytics_calculator.dart';

/// КПД рабочего места.
///
/// Скорость месяца = qty(work) / useful_minutes(work).
/// КПД = скорость_текущего / средняя_скорость_предыдущих_месяцев × 100%.
class KpdResult {
  final double currentSpeed;
  final double previousAverageSpeed;
  final double kpdPercent;
  final bool noBaseline;

  const KpdResult({
    required this.currentSpeed,
    required this.previousAverageSpeed,
    required this.kpdPercent,
    required this.noBaseline,
  });
}

class KpdCalculator {
  KpdCalculator._();

  /// Считает скорость на месяце для рабочего места по списку событий месяца.
  static double speedForMonth(
      List<AnalyticsEvent> eventsOfMonthForWorkplace) {
    return AnalyticsCalculator.speedQtyPerMinute(eventsOfMonthForWorkplace);
  }

  /// Считает КПД, имея скорость текущего месяца и скорости предыдущих.
  /// Если предыдущих скоростей нет — возвращает 100% с пометкой noBaseline.
  static KpdResult compute({
    required double currentSpeed,
    required List<double> previousMonthsSpeeds,
  }) {
    final filtered = previousMonthsSpeeds.where((s) => s.isFinite && s > 0).toList();
    if (filtered.isEmpty) {
      return KpdResult(
        currentSpeed: currentSpeed,
        previousAverageSpeed: 0,
        kpdPercent: 100,
        noBaseline: true,
      );
    }
    final avg = filtered.reduce((a, b) => a + b) / filtered.length;
    if (avg <= 0) {
      return KpdResult(
        currentSpeed: currentSpeed,
        previousAverageSpeed: 0,
        kpdPercent: 100,
        noBaseline: true,
      );
    }
    final kpd = (currentSpeed / avg) * 100;
    return KpdResult(
      currentSpeed: currentSpeed,
      previousAverageSpeed: avg,
      kpdPercent: kpd.isFinite ? kpd : 0,
      noBaseline: false,
    );
  }

  /// Хелпер: получает список (месяц -> события) и возвращает скорости.
  static List<double> speedsForMonths({
    required Map<AnalyticsMonth, List<AnalyticsEvent>> eventsByMonth,
  }) {
    final out = <double>[];
    eventsByMonth.forEach((_, events) {
      out.add(speedForMonth(events));
    });
    return out;
  }
}
