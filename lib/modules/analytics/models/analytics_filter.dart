import 'analytics_month.dart';
import '../utils/analytics_constants.dart';

/// Глобальный фильтр аналитики.
class AnalyticsFilter {
  final AnalyticsMonth month;
  final String? employeeId;
  final String workplaceFilter;
  final int? selectedDay; // 1..31

  AnalyticsFilter({
    AnalyticsMonth? month,
    this.employeeId,
    this.workplaceFilter = AnalyticsConstants.allWorkplaces,
    this.selectedDay,
  }) : month = month ?? AnalyticsMonth.current();

  AnalyticsFilter copyWith({
    AnalyticsMonth? month,
    String? employeeId,
    String? workplaceFilter,
    int? selectedDay,
    bool clearEmployee = false,
    bool clearDay = false,
  }) {
    return AnalyticsFilter(
      month: month ?? this.month,
      employeeId: clearEmployee ? null : (employeeId ?? this.employeeId),
      workplaceFilter: workplaceFilter ?? this.workplaceFilter,
      selectedDay: clearDay ? null : (selectedDay ?? this.selectedDay),
    );
  }
}
