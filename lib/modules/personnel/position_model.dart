class PositionModel {
  final String id;
  final String name;

  PositionModel({required this.id, required this.name});
  
  /// Преобразование модели в Map для хранения в Supabase.
  Map<String, dynamic> toMap() => {
        'name': name,
      };

  /// Создание модели из Map, полученного из Supabase.
  factory PositionModel.fromMap(Map<String, dynamic> map, String id) =>
      PositionModel(id: id, name: map['name'] as String? ?? '');
}