class PositionModel {
  final String id;
  final String name;

  PositionModel({required this.id, required this.name});
  
  /// Преобразование модели в [Map] для сохранения в базе данных.
  ///
  /// Эта структура используется Supabase для сериализации записи
  /// должности в таблице `positions`.
  Map<String, dynamic> toMap() => {
        'name': name,
      };

  /// Создание модели из [Map], полученного из базы данных.
  factory PositionModel.fromMap(Map<String, dynamic> map, String id) =>
      PositionModel(id: id, name: map['name'] as String? ?? '');
}