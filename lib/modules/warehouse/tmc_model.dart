class TmcModel {
  final String id;
  final String date;
  final String? supplier;
  final String type;
  final String description;
  final double quantity;
  final String unit;
  final String? note;

  TmcModel({
    required this.id,
    required this.date,
    this.supplier,
    required this.type,
    required this.description,
    required this.quantity,
    required this.unit,
    this.note,
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
    };
  }
}
