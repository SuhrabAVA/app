class TmcModel {
  final String id;
  final String date;
  final String? supplier;
  final String type;
  final String description;
  final double quantity;
  final String unit;
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
    this.note,
    this.imageUrl,
    this.imageBase64,
  });

  // Для преобразования из Firebase Map
  factory TmcModel.fromMap(Map<String, dynamic> map) {
    return TmcModel(
      id: map['id'] ?? '',
      date: map['date'] ?? '',
      supplier: map['supplier'],
      type: map['type'] ?? '',
      description: map['description'] ?? '',
      quantity: (map['quantity'] as num).toDouble(),
      unit: map['unit'] ?? '',
      note: map['note'],
      imageUrl: map['imageUrl'],
      imageBase64: map['imageBase64'],
    );
  }

  // Для сохранения в Firebase
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'date': date,
      'supplier': supplier,
      'type': type,
      'description': description,
      'quantity': quantity,
      'unit': unit,
      'note': note,
      if (imageUrl != null) 'imageUrl': imageUrl,
      if (imageBase64 != null) 'imageBase64': imageBase64,
    };
  }
}
