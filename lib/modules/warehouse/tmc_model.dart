class TmcModel {
  final String id;
  final String date;
  final String? supplier;
  final String type;
  final String description;
  final double quantity;
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

  TmcModel({
    required this.id,
    required this.date,
    this.supplier,
    required this.type,
    required this.description,
    required this.quantity,
    required this.unit,
    this.format,
    this.grammage,
    this.weight,
    this.note,
    this.imageUrl,
    this.imageBase64,
  });

  // Создание модели из [Map], полученного из базы данных (например, Supabase).
  factory TmcModel.fromMap(Map<String, dynamic> map) {
    return TmcModel(
      id: map['id'] ?? '',
      date: map['date'] ?? '',
      supplier: map['supplier'],
      type: map['type'] ?? '',
      description: map['description'] ?? '',
      quantity: (map['quantity'] as num?)?.toDouble() ?? 0.0,
      unit: map['unit'] ?? '',
      format: map['format'],
      grammage: map['grammage'],
      weight: (map['weight'] as num?)?.toDouble(),
      note: map['note'],
      // image fields may come in different cases or snake_case from Postgres
      imageUrl: map['image_url'] ?? map['imageUrl'] ?? map['imageurl'],
      imageBase64: map['image_base64'] ?? map['imageBase64'] ?? map['imagebase64'],
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
      'unit': unit,
      if (format != null) 'format': format,
      if (grammage != null) 'grammage': grammage,
      if (weight != null) 'weight': weight,
      'note': note,
      // write image fields in snake_case to align with Postgres schema
      if (imageUrl != null) 'image_url': imageUrl,
      if (imageBase64 != null) 'image_base64': imageBase64,
    };
  }
}
