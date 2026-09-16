/// Модель продукта внутри заказа.
class ProductModel {
  final String id;
  String type; // наименование изделия (код/название)
  int quantity; // тираж
  double width;
  double height;
  double depth;
  String parameters; // параметры продукта (строка)
  double? roll;
  double? widthB;
  String? blQuantity;
  double? length;
  double? leftover;

  ProductModel({
    required this.id,
    required this.type,
    required this.quantity,
    required this.width,
    required this.height,
    required this.depth,
    this.parameters = '',
    this.roll,
    this.widthB,
    this.blQuantity,
    this.length,
    this.leftover,
  });

  /// Габариты одной строкой: «12×81×41».
  ///
  /// Нули пропускаются (у листовых изделий глубины нет), дробные значения
  /// показываются без хвостовых нулей. Пусто, если размеры не заполнены.
  String get sizeLabel {
    String? format(double value) {
      if (value <= 0) return null;
      if (value == value.roundToDouble()) return value.toInt().toString();
      return value
          .toStringAsFixed(2)
          .replaceAll(RegExp(r'0+$'), '')
          .replaceAll(RegExp(r'\.$'), '');
    }

    return [format(width), format(height), format(depth)]
        .whereType<String>()
        .join('×');
  }

  /// Преобразует модель продукта в Map.
  Map<String, dynamic> toMap() => {
        'id': id,
        'type': type,
        'quantity': quantity,
        'width': width,
        'height': height,
        'depth': depth,
        'parameters': parameters,
        if (roll != null) 'roll': roll,
        if (widthB != null) 'widthB': widthB,
        if (blQuantity != null && blQuantity!.isNotEmpty)
          'blQuantity': blQuantity,
        if (length != null) 'length': length,
        if (leftover != null) 'leftover': leftover,
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
        roll: (map['roll'] as num?)?.toDouble(),
        widthB: (map['widthB'] as num?)?.toDouble(),
        blQuantity: map['blQuantity']?.toString(),
        length: (map['length'] as num?)?.toDouble(),
        leftover: (map['leftover'] as num?)?.toDouble(),
      );
}
