class TerminalModel {
  final String id;
  final String name;
  final List<String> workplaceIds;

  TerminalModel({
    required this.id,
    required this.name,
    required this.workplaceIds,
  });
  /// Преобразование модели терминала в [Map] для сохранения в базе данных.
  ///
  /// Supabase использует эту структуру при вставке или обновлении
  /// записей в таблице `terminals`.
  Map<String, dynamic> toMap() => {
        'name': name,
        'workplaceIds': workplaceIds,
      };

  /// Создание модели из [Map], полученного из базы данных.
  factory TerminalModel.fromMap(Map<String, dynamic> map, String id) =>
      TerminalModel(
        id: id,
        name: map['name'] as String? ?? '',
        workplaceIds: List<String>.from(map['workplaceIds'] ?? []),
      );
}