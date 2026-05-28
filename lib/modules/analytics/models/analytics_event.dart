import '../utils/analytics_constants.dart';

/// Тип события аналитики.
enum AnalyticsEventType {
  work,
  pause,
  problem,
  setup,
  idle, // вычисляется автоматически, не хранится в БД
}

extension AnalyticsEventTypeX on AnalyticsEventType {
  String get label {
    switch (this) {
      case AnalyticsEventType.work:
        return 'Работа';
      case AnalyticsEventType.pause:
        return 'Пауза';
      case AnalyticsEventType.problem:
        return 'Проблема';
      case AnalyticsEventType.setup:
        return 'Наладка';
      case AnalyticsEventType.idle:
        return 'Простой';
    }
  }
}

/// Единое событие аналитики, на основе TaskTimeEvent + qty из comments.
class AnalyticsEvent {
  final String id;
  final AnalyticsEventType type;
  final DateTime startTime;
  final DateTime? endTime; // null — событие активно
  final String employeeId;
  final String workplaceId;
  final String taskId;
  final String orderId;
  final String? customer;
  final String? note;
  /// Количество, выполненное в рамках этого события (для работы).
  final double qty;
  /// Количество приладки (для наладки).
  final double setupQty;
  /// Сделано ли событие сегодня (для подсветки активности).
  final bool isActive;

  const AnalyticsEvent({
    required this.id,
    required this.type,
    required this.startTime,
    required this.endTime,
    required this.employeeId,
    required this.workplaceId,
    required this.taskId,
    required this.orderId,
    this.customer,
    this.note,
    this.qty = 0,
    this.setupQty = 0,
    this.isActive = false,
  });

  /// Длительность события в минутах. Если endTime отсутствует — возвращает 0
  /// (но активные события UI может растягивать до now()).
  int durationMinutes() {
    if (endTime == null) return 0;
    final diff = endTime!.difference(startTime).inMinutes;
    return diff < 0 ? 0 : diff;
  }

  /// Длительность с учётом текущего момента для активных событий.
  int durationMinutesEffective(DateTime now) {
    final end = endTime ?? now;
    final diff = end.difference(startTime).inMinutes;
    return diff < 0 ? 0 : diff;
  }

  AnalyticsEvent copyWith({
    DateTime? endTime,
    String? note,
    double? qty,
    double? setupQty,
    bool? isActive,
    String? customer,
  }) {
    return AnalyticsEvent(
      id: id,
      type: type,
      startTime: startTime,
      endTime: endTime ?? this.endTime,
      employeeId: employeeId,
      workplaceId: workplaceId,
      taskId: taskId,
      orderId: orderId,
      customer: customer ?? this.customer,
      note: note ?? this.note,
      qty: qty ?? this.qty,
      setupQty: setupQty ?? this.setupQty,
      isActive: isActive ?? this.isActive,
    );
  }
}

/// Применимо для timeline: одно из сырьевых событий + признак «всё рабочее место».
bool acceptsWorkplaceFilter(AnalyticsEvent event, String filterWorkplaceId) {
  if (filterWorkplaceId == AnalyticsConstants.allWorkplaces) return true;
  return event.workplaceId == filterWorkplaceId;
}
