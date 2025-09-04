class WorkplaceModel {
  final String id;
  final String name;
  final List<String> positionIds;

  WorkplaceModel({
    required this.id,
    required this.name,
    required this.positionIds,
  });
   /// Преобразование модели рабочего места в Map для Firebase.
  Map<String, dynamic> toMap() => {
        'name': name,
        'positionIds': positionIds,
      };

  /// Создание модели из Map, полученного из Firebase.
  factory WorkplaceModel.fromMap(Map<String, dynamic> map, String id) =>
      WorkplaceModel(
        id: id,
        name: map['name'] as String? ?? '',
        positionIds: List<String>.from(map['positionIds'] ?? []),
      );
}