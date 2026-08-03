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

/// Строка истории статуса сотрудника (как хранится в employee_status_history).
/// [dateTo] исключительна: период покрывает дни [dateFrom, dateTo).
/// null означает, что период ещё открыт (статус активен по сей день).
class EmployeeStatusHistoryRow {
  final String id;
  final String employeeId;
  final String statusId;
  final DateTime dateFrom;
  final DateTime? dateTo;

  const EmployeeStatusHistoryRow({
    required this.id,
    required this.employeeId,
    required this.statusId,
    required this.dateFrom,
    this.dateTo,
  });

  factory EmployeeStatusHistoryRow.fromMap(Map<String, dynamic> map) {
    DateTime parseDate(dynamic v) => DateTime.parse(v.toString());
    return EmployeeStatusHistoryRow(
      id: (map['id'] ?? '').toString(),
      employeeId: (map['employee_id'] ?? '').toString(),
      statusId: (map['status_id'] ?? '').toString(),
      dateFrom: parseDate(map['date_from']),
      dateTo: map['date_to'] == null ? null : parseDate(map['date_to']),
    );
  }
}
