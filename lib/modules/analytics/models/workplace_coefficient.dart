class WorkplaceCoefficient {
  final String id;
  final String workplaceId;
  final double coefficient;
  final DateTime effectiveMonth;

  const WorkplaceCoefficient({
    required this.id,
    required this.workplaceId,
    required this.coefficient,
    required this.effectiveMonth,
  });

  factory WorkplaceCoefficient.fromMap(Map<String, dynamic> map) {
    double parseCoeff(dynamic v) {
      if (v == null) return 0;
      if (v is num) return v.toDouble();
      return double.tryParse(v.toString()) ?? 0;
    }

    DateTime parseDate(dynamic v) {
      if (v is DateTime) return v;
      if (v is String) return DateTime.parse(v);
      return DateTime.now();
    }

    return WorkplaceCoefficient(
      id: (map['id'] ?? '').toString(),
      workplaceId: (map['workplace_id'] ?? '').toString(),
      coefficient: parseCoeff(map['coefficient']),
      effectiveMonth: parseDate(map['effective_month']),
    );
  }
}
