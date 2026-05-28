class ClaimModel {
  final String id;
  final String orderId;
  final String? commentId;
  final String employeeId;
  final String? workplaceId;
  final String? description;
  final String? createdBy;
  final DateTime createdAt;

  const ClaimModel({
    required this.id,
    required this.orderId,
    this.commentId,
    required this.employeeId,
    this.workplaceId,
    this.description,
    this.createdBy,
    required this.createdAt,
  });

  factory ClaimModel.fromMap(Map<String, dynamic> map) {
    DateTime parseDt(dynamic v) {
      if (v is DateTime) return v;
      if (v is String) return DateTime.tryParse(v) ?? DateTime.now();
      return DateTime.now();
    }

    return ClaimModel(
      id: (map['id'] ?? '').toString(),
      orderId: (map['order_id'] ?? '').toString(),
      commentId: map['comment_id']?.toString(),
      employeeId: (map['employee_id'] ?? '').toString(),
      workplaceId: map['workplace_id']?.toString(),
      description: map['description']?.toString(),
      createdBy: map['created_by']?.toString(),
      createdAt: parseDt(map['created_at']),
    );
  }
}
