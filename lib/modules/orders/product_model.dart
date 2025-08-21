/// Модель продукта внутри заказа.
class ProductModel {
  final String id;
  String type; // наименование изделия (код/название)
  int quantity; // тираж
  double width;
  double height;
  double depth;
  String parameters; // параметры продукта (строка)

  ProductModel({
    required this.id,
    required this.type,
    required this.quantity,
    required this.width,
    required this.height,
    required this.depth,
    this.parameters = '',
  });

  /// Преобразует модель продукта в Map.
  Map<String, dynamic> toMap() => {
        'id': id,
        'type': type,
        'quantity': quantity,
        'width': width,
        'height': height,
        'depth': depth,
        'parameters': parameters,
      };

  /// Создаёт [ProductModel] из Map.
  factory ProductModel.fromMap(Map<String, dynamic> map) => ProductModel(
        id: map['id'] as String? ?? '',
        type: map['type'] as String? ?? '',
        quantity: (map['quantity'] as num?)?.toInt() ?? 0,
        width: (map['width'] as num?)?.toDouble() ?? 0,
        height: (map['height'] as num?)?.toDouble() ?? 0,
        depth: (map['depth'] as num?)?.toDouble() ?? 0,
        parameters: map['parameters'] as String? ?? '',
      );
}