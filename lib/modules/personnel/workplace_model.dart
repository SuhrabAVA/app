class WorkplaceModel {
  final String id;
  final String name;
  final List<String> positionIds;
  /// Признак наличия станка/оборудования на рабочем месте.
  final bool hasMachine;
  /// Максимальное количество сотрудников, которые могут одновременно работать на этом месте.
  final int maxConcurrentWorkers;

  WorkplaceModel({
    required this.id,
    required this.name,
    required this.positionIds,
    this.hasMachine = false,
    this.maxConcurrentWorkers = 1,
  });

  /// Преобразование модели рабочего места в [Map] для сохранения в базе данных.
  /// В Supabase это представление используется для вставки или обновления
  /// строки в таблице `workplaces`.
  Map<String, dynamic> toMap() => {
        'name': name,
        'positionIds': positionIds,
        'has_machine': hasMachine,
        'max_concurrent_workers': maxConcurrentWorkers,
      };

  /// Создание модели из [Map], полученного из базы данных. Использует snake_case
  /// для чтения полей Supabase.
  factory WorkplaceModel.fromMap(Map<String, dynamic> map, String id) =>
      WorkplaceModel(
        id: id,
        name: map['name'] as String? ?? '',
        positionIds: List<String>.from(map['positionIds'] ?? []),
        hasMachine: map['has_machine'] as bool? ?? map['hasMachine'] as bool? ?? false,
        maxConcurrentWorkers: (map['max_concurrent_workers'] as int?) ?? (map['maxConcurrentWorkers'] as int?) ?? 1,
      );
}