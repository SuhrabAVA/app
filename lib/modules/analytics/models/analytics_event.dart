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

/// Запись количества, из которой сложилось [AnalyticsEvent.qty].
///
/// Нужна, чтобы по числу в таблице можно было добраться до исходного
/// комментария и исправить его: одно событие часто вбирает несколько записей
/// (перерывы + завершение), и без ссылок непонятно, какую из них править.
class AnalyticsQtySource {
  /// id комментария в `tasks.comments`.
  final String commentId;

  /// `quantity_done` / `quantity_team_total` / `quantity_share`.
  final String type;

  /// Что этот комментарий дал в [AnalyticsEvent.qty] — уже в единицах
  /// рабочего места (для упаковки это упаковки, а не введённые штуки).
  final double qty;

  /// Момент фиксации — по нему сотрудник узнаёт свою запись в списке.
  final DateTime timestamp;

  /// Исходный текст комментария (payload количества).
  ///
  /// Нужен диалогу правки: в аналитике упаковка показана в УПАКОВКАХ, а
  /// правится введённое число — штуки. Без payload не узнать ни единицу
  /// хранения, ни фасовку.
  final String rawText;

  const AnalyticsQtySource({
    required this.commentId,
    required this.type,
    required this.qty,
    required this.timestamp,
    this.rawText = '',
  });
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

  /// Записи, из которых сложилось [qty] — для правки количества техлидом.
  final List<AnalyticsQtySource> qtySources;
  /// Количество приладки (для наладки).
  final double setupQty;
  /// Сделано ли событие сегодня (для подсветки активности).
  final bool isActive;

  /// Помощник в совместной работе: этап начал и ведёт другой сотрудник.
  ///
  /// Количество после завершения этапа засчитывается всем участникам
  /// целиком, поэтому по одному только qty помощника от основного
  /// исполнителя не отличить — роль приходится нести в самом событии.
  /// Оплачивается по своей ставке (см. WorkplaceCoefficient.helperCoefficient).
  final bool isHelper;

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
    this.qtySources = const <AnalyticsQtySource>[],
    this.setupQty = 0,
    this.isActive = false,
    this.isHelper = false,
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
    bool? isHelper,
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
      qtySources: qtySources,
      setupQty: setupQty ?? this.setupQty,
      isActive: isActive ?? this.isActive,
      isHelper: isHelper ?? this.isHelper,
    );
  }
}

/// Применимо для timeline: одно из сырьевых событий + признак «всё рабочее место».
bool acceptsWorkplaceFilter(AnalyticsEvent event, String filterWorkplaceId) {
  if (filterWorkplaceId == AnalyticsConstants.allWorkplaces) return true;
  return event.workplaceId == filterWorkplaceId;
}
