class StageModel {
  final String id;
  final String name;
  final String description;
  final String workplaceId;

  StageModel({
    required this.id,
    required this.name,
    required this.description,
    required this.workplaceId,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'description': description,
        'workplaceId': workplaceId,
      };

  factory StageModel.fromMap(Map<String, dynamic> map) => StageModel(
        id: map['id'] as String? ?? '',
        name: map['name'] as String? ?? '',
        description: map['description'] as String? ?? '',
        workplaceId: map['workplaceId'] as String? ?? '',
      );
}