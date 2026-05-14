class TmcModel {
  final String id;
  final String date;
  final String? supplier;
  final String type;
  final String description;
  final double quantity;

  /// Количество, зарезервированное под заказы.
  final double reservedQty;

  /// Доступный остаток: общий остаток минус резерв.
  final double availableQty;
  final String unit;
  final String? format; // для бумаги
  final String? grammage; // граммаж бумаги
  final double? weight; // вес бумаги
  final String? note;

  /// URL изображения, если для записи загрузили фото (например, для красок).
  final String? imageUrl;

  /// base64-строка изображения. Используется для отображения изображений без
  /// необходимости загружать их из интернета (например, в веб-версии).
  final String? imageBase64;

  /// Пороговое значение для предупреждения о низком остатке (желтый индикатор).
  final double? lowThreshold;

  /// Пороговое значение для предупреждения о критически низком остатке (красный индикатор).
  final double? criticalThreshold;

  /// Время создания записи (ISO 8601). Используется для отображения даты/времени в UI.
  final String? createdAt;

  /// Время последнего обновления записи (ISO 8601). Используется для отображения даты/времени в UI.
  final String? updatedAt;

  const TmcModel({
    required this.id,
    required this.date,
    this.supplier,
    required this.type,
    required this.description,
    required this.quantity,
    double? reservedQty,
    double? availableQty,
    required this.unit,
    this.format,
    this.grammage,
    this.weight,
    this.note,
    this.imageUrl,
    this.imageBase64,
    this.lowThreshold,
    this.criticalThreshold,
    this.createdAt,
    this.updatedAt,
  })  : reservedQty = reservedQty ?? 0.0,
        availableQty = availableQty ?? (quantity - (reservedQty ?? 0.0));

  // Создание модели из [Map], полученного из базы данных (например, Supabase).
  factory TmcModel.fromMap(Map<String, dynamic> map) {
    final quantity = (map['quantity'] as num?)?.toDouble() ?? 0.0;
    final reservedQty = (map['reserved_qty'] ?? map['reservedQty']) is num
        ? ((map['reserved_qty'] ?? map['reservedQty']) as num).toDouble()
        : double.tryParse(
              '${map['reserved_qty'] ?? map['reservedQty'] ?? ''}',
            ) ??
            0.0;
    final availableQty = (map['available_qty'] ?? map['availableQty']) is num
        ? ((map['available_qty'] ?? map['availableQty']) as num).toDouble()
        : double.tryParse(
              '${map['available_qty'] ?? map['availableQty'] ?? ''}',
            ) ??
            (quantity - reservedQty);
    return TmcModel(
      id: map['id'] ?? '',
      date: map['date'] ?? '',
      supplier: map['supplier'],
      type: map['type'] ?? '',
      description: map['description'] ?? '',
      quantity: quantity,
      reservedQty: reservedQty,
      availableQty: availableQty,
      unit: map['unit'] ?? '',
      format: map['format'],
      grammage: map['grammage'],
      weight: (map['weight'] as num?)?.toDouble(),
      note: map['note'],
      // image fields may come in different cases or snake_case from Postgres
      imageUrl: map['image_url'] ?? map['imageUrl'] ?? map['imageurl'],
      imageBase64:
          map['image_base64'] ?? map['imageBase64'] ?? map['imagebase64'],
      lowThreshold: (map['low_threshold'] ?? map['lowThreshold']) is num
          ? (map['low_threshold'] ?? map['lowThreshold'])?.toDouble()
          : null,
      criticalThreshold:
          (map['critical_threshold'] ?? map['criticalThreshold']) is num
              ? (map['critical_threshold'] ?? map['criticalThreshold'])
                  ?.toDouble()
              : null,
      createdAt: map['created_at'] ?? map['createdAt'],
      updatedAt: map['updated_at'] ?? map['updatedAt'],
    );
  }

  // Создаёт [Map] для сохранения записи в базе данных (например, Supabase)
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'date': date,
      'supplier': supplier,
      'type': type,
      'description': description,
      'quantity': quantity,
      'reserved_qty': reservedQty,
      'available_qty': availableQty,
      'unit': unit,
      if (format != null) 'format': format,
      if (grammage != null) 'grammage': grammage,
      if (weight != null) 'weight': weight,
      'note': note,
      // write image fields in snake_case to align with Postgres schema
      if (imageUrl != null) 'image_url': imageUrl,
      if (imageBase64 != null) 'image_base64': imageBase64,
      if (lowThreshold != null) 'low_threshold': lowThreshold,
      if (criticalThreshold != null) 'critical_threshold': criticalThreshold,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
    };
  }

  factory TmcModel.fromJson(Map<String, dynamic> json) => TmcModel.fromMap(json);

  Map<String, dynamic> toJson() => toMap();

  TmcModel copyWith({
    String? id,
    String? date,
    String? supplier,
    String? type,
    String? description,
    double? quantity,
    double? reservedQty,
    double? availableQty,
    String? unit,
    String? format,
    String? grammage,
    double? weight,
    String? note,
    String? imageUrl,
    String? imageBase64,
    double? lowThreshold,
    double? criticalThreshold,
    String? createdAt,
    String? updatedAt,
  }) {
    final nextQuantity = quantity ?? this.quantity;
    final nextReservedQty = reservedQty ?? this.reservedQty;
    return TmcModel(
      id: id ?? this.id,
      date: date ?? this.date,
      supplier: supplier ?? this.supplier,
      type: type ?? this.type,
      description: description ?? this.description,
      quantity: nextQuantity,
      reservedQty: nextReservedQty,
      availableQty: availableQty ?? (nextQuantity - nextReservedQty),
      unit: unit ?? this.unit,
      format: format ?? this.format,
      grammage: grammage ?? this.grammage,
      weight: weight ?? this.weight,
      note: note ?? this.note,
      imageUrl: imageUrl ?? this.imageUrl,
      imageBase64: imageBase64 ?? this.imageBase64,
      lowThreshold: lowThreshold ?? this.lowThreshold,
      criticalThreshold: criticalThreshold ?? this.criticalThreshold,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}
