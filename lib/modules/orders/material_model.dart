/// Материал (например, бумага) для заказа.
class MaterialModel {
  final String? id;
  final String name;
  final double quantity;     // теперь НЕ обязательный (по умолчанию 0.0)
  final String unit;         // теперь НЕ обязательный (по умолчанию "шт")
  final String? format;
  final String? grammage;
  final double? weight;
  final Map<String, dynamic>? extra;

  const MaterialModel({
    this.id,
    required this.name,
    double? quantity,          // <-- необязательный
    String? unit,              // <-- необязательный
    this.format,
    this.grammage,
    this.weight,
    this.extra,
  })  : quantity = quantity ?? 0.0,
        unit = unit ?? 'шт';

  factory MaterialModel.fromMap(Map<String, dynamic> m) {
    double toDouble(dynamic v) =>
        v is int ? v.toDouble() : (v as num?)?.toDouble() ?? 0.0;

    return MaterialModel(
      id: m['id'] as String?,
      name: (m['name'] ?? '') as String,
      quantity: toDouble(m['quantity']),
      unit: (m['unit'] ?? 'шт') as String,
      format: m['format'] as String?,
      grammage: m['grammage'] as String?,
      weight: toDouble(m['weight']),
      extra: m['extra'] is Map<String, dynamic>
          ? m['extra'] as Map<String, dynamic>
          : (m['extra'] is Map ? Map<String, dynamic>.from(m['extra'] as Map) : null),
    );
  }

  Map<String, dynamic> toMap() => {
        if (id != null) 'id': id,
        'name': name,
        'quantity': quantity,
        'unit': unit,
        if (format != null) 'format': format,
        if (grammage != null) 'grammage': grammage,
        if (weight != null) 'weight': weight,
        if (extra != null) 'extra': extra,
      };

  MaterialModel copyWith({
    String? id,
    String? name,
    double? quantity,
    String? unit,
    String? format,
    String? grammage,
    double? weight,
    Map<String, dynamic>? extra,
  }) {
    return MaterialModel(
      id: id ?? this.id,
      name: name ?? this.name,
      quantity: quantity ?? this.quantity,
      unit: unit ?? this.unit,
      format: format ?? this.format,
      grammage: grammage ?? this.grammage,
      weight: weight ?? this.weight,
      extra: extra ?? this.extra,
    );
  }
}
