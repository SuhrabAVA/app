class WorkplaceModel {
  final String id;
  final String name;
  final List<String> positionIds;

  WorkplaceModel({
    required this.id,
    required this.name,
    required this.positionIds,
  });
  /// Преобразование модели рабочего места в [Map] для сохранения в базе данных.
  ///
  /// В Supabase это представление используется для вставки или обновления
  /// строки в таблице `workplaces`. Значения id и name будут
  /// сериализованы в JSON.
  Map<String, dynamic> toMap() => {
        'name': name,
        'positionIds': positionIds,
      };

  /// Создание модели из [Map], полученного из базы данных.
  ///
  /// Supabase возвращает строки из таблицы `workplaces` в виде [Map],
  /// поэтому этот конструктор выделяет необходимые поля и формирует
  /// корректный экземпляр модели.
  factory WorkplaceModel.fromMap(Map<String, dynamic> map, String id) =>
      WorkplaceModel(
        id: id,
        name: map['name'] as String? ?? '',
        positionIds: List<String>.from(map['positionIds'] ?? []),
      );
}