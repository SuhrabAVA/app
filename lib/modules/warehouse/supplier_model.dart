class SupplierModel {
  /// Уникальный идентификатор поставщика
  final String id;
  /// Название компании-поставщика
  final String name;
  /// Бизнес‑идентификационный номер (БИН)
  final String bin;
  /// Контактное лицо от поставщика
  final String contact;
  /// Телефонный номер поставщика или контактного лица
  final String phone;

  SupplierModel({
    required this.id,
    required this.name,
    required this.bin,
    required this.contact,
    required this.phone,
  });

  factory SupplierModel.fromMap(Map<String, dynamic> map) {
    return SupplierModel(
      id: map['id'] ?? '',
      name: map['name'] ?? '',
      bin: map['bin'] ?? '',
      contact: map['contact'] ?? '',
      phone: map['phone'] ?? '',
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'bin': bin,
      'contact': contact,
      'phone': phone,
    };
  }
}