/// Модель материала (бумаги), выбираемого из склада.
/// Содержит основные характеристики, которые подставляются в заказ.
class MaterialModel {
  final String id;
  final String name; // название бумаги
  final String format; // формат листа или рулона
  final String grammage; // граммаж
  final double? weight; // вес, если требуется

  MaterialModel({
    required this.id,
    required this.name,
    required this.format,
    required this.grammage,
    this.weight,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'format': format,
        'grammage': grammage,
        if (weight != null) 'weight': weight,
      };

  factory MaterialModel.fromMap(Map<String, dynamic> map) => MaterialModel(
        id: map['id'] as String? ?? '',
        name: map['name'] as String? ?? '',
        format: map['format'] as String? ?? '',
        grammage: map['grammage'] as String? ?? '',
        weight: (map['weight'] as num?)?.toDouble(),
      );
}
