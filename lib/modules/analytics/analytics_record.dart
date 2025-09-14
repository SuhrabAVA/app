/// Модель записи аналитики.
///
/// Каждая запись описывает действие сотрудника на определённом этапе заказа:
/// кто выполнил действие, с каким заказом и этапом оно связано, тип
/// действия и отметку времени. Тип действия принимает значения
/// `start`, `pause`, `resume`, `finish` или `problem`.
class AnalyticsRecord {
  final String id;
  final String orderId;
  final String stageId;
  final String userId;
  final String action;
  final String category;
  final String details;
  final int timestamp;

  AnalyticsRecord({
    required this.id,
    required this.orderId,
    required this.stageId,
    required this.userId,
    required this.action,
    required this.category,
    required this.details,
    required this.timestamp,
  });

  factory AnalyticsRecord.fromMap(Map<String, dynamic> map, String id) {
    return AnalyticsRecord(
      id: id,
      orderId: map['orderId'] as String? ?? '',
      stageId: map['stageId'] as String? ?? '',
      userId: map['userId'] as String? ?? '',
      action: map['action'] as String? ?? '',
      category: map['category'] as String? ?? '',
      details: map['details'] as String? ?? '',
      timestamp: map['timestamp'] is int ? map['timestamp'] as int : 0,
    );
  }

  Map<String, dynamic> toMap() => {
        'orderId': orderId,
        'stageId': stageId,
        'userId': userId,
        'action': action,
        'category': category,
        'details': details,
        'timestamp': timestamp,
      };
}