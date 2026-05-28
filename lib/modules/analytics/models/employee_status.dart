class EmployeeStatus {
  final String id;
  final String name;
  final String? description;
  final String? color;

  const EmployeeStatus({
    required this.id,
    required this.name,
    this.description,
    this.color,
  });

  factory EmployeeStatus.fromMap(Map<String, dynamic> map) {
    return EmployeeStatus(
      id: (map['id'] ?? '').toString(),
      name: (map['name'] ?? '').toString(),
      description: map['description']?.toString(),
      color: map['color']?.toString(),
    );
  }
}
