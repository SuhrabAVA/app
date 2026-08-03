/// Отображаемое событие/комментарий этапа для лент дня аналитики.
///
/// Аддитивный слой поверх расчётных [AnalyticsEvent]: собирается из
/// tasks.comments теми типами, которые НЕ участвуют в расчёте зарплаты/КПД
/// (комментарии, проблемы, паузы, старт/завершение этапов и т.п.).
/// На цифры зарплаты и КПД не влияет.
class AnalyticsDayComment {
  final String id;
  final String type;
  final String text;
  final String userId;
  final DateTime timestamp;
  final String taskId;
  final String orderId;
  final String workplaceId;
  final String? customer;

  const AnalyticsDayComment({
    required this.id,
    required this.type,
    required this.text,
    required this.userId,
    required this.timestamp,
    required this.taskId,
    required this.orderId,
    required this.workplaceId,
    this.customer,
  });
}
