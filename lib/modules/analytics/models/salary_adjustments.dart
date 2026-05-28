/// Ручные корректировки зарплаты сотрудника за месяц.
class SalaryAdjustments {
  final String? id;
  final String employeeId;
  final DateTime month;
  final double compensation;
  final double social;
  final double advance;
  final double cashless;
  final double discipline;
  final double defect;

  const SalaryAdjustments({
    this.id,
    required this.employeeId,
    required this.month,
    this.compensation = 0,
    this.social = 0,
    this.advance = 0,
    this.cashless = 0,
    this.discipline = 0,
    this.defect = 0,
  });

  factory SalaryAdjustments.zero(String employeeId, DateTime month) =>
      SalaryAdjustments(employeeId: employeeId, month: month);

  factory SalaryAdjustments.fromMap(Map<String, dynamic> map) {
    double pd(dynamic v) {
      if (v == null) return 0;
      if (v is num) return v.toDouble();
      return double.tryParse(v.toString()) ?? 0;
    }

    DateTime parseDate(dynamic v) {
      if (v is DateTime) return v;
      if (v is String) return DateTime.parse(v);
      return DateTime.now();
    }

    return SalaryAdjustments(
      id: map['id']?.toString(),
      employeeId: (map['employee_id'] ?? '').toString(),
      month: parseDate(map['month']),
      compensation: pd(map['compensation']),
      social: pd(map['social']),
      advance: pd(map['advance']),
      cashless: pd(map['cashless']),
      discipline: pd(map['discipline']),
      defect: pd(map['defect']),
    );
  }

  SalaryAdjustments copyWith({
    double? compensation,
    double? social,
    double? advance,
    double? cashless,
    double? discipline,
    double? defect,
  }) =>
      SalaryAdjustments(
        id: id,
        employeeId: employeeId,
        month: month,
        compensation: compensation ?? this.compensation,
        social: social ?? this.social,
        advance: advance ?? this.advance,
        cashless: cashless ?? this.cashless,
        discipline: discipline ?? this.discipline,
        defect: defect ?? this.defect,
      );
}
